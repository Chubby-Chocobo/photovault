import Foundation
import GRDB
import PhotoVaultCore

/// `upload_job`. State rules live in `JobTransitions`; this type only reads, calls it, and writes.
public enum JobRepository {
    /// A job that may start uploading, with the resource it will read (nil for sidecars).
    public struct ReadyJob: Sendable, Hashable {
        public var job: UploadJob
        public var resource: ResourceRecord?
    }

    // MARK: Upsert and transitions

    /// Read → `JobTransitions.upsert` → write. Returns the written job, or nil when nothing changed.
    /// An original-file job created or reinstated as a backfill job joins the open run of `runTrigger`.
    @discardableResult
    public static func upsert(
        _ db: Database, desired: JobTransitions.Desired, now: Date, runTrigger: BackfillTrigger = .library
    ) throws -> UploadJob? {
        let existing = try fetch(db, identity: desired.identity)
        guard var updated = JobTransitions.upsert(existing: existing, desired: desired, now: now) else { return nil }
        if !updated.resType.isSidecar, updated.origin == .backfill || updated.origin == .destinationBackfill,
           existing == nil || existing?.state == .cancelled {
            updated.backfillRunId = try BackfillRunRepository.runId(
                db, trigger: runTrigger, destinationId: updated.destinationId, now: now)
        }
        try save(db, &updated)
        return updated
    }

    /// Read → `JobTransitions.apply` → write. Throws `StoreError.notFound` or `JobTransitionError`.
    @discardableResult
    public static func apply(_ db: Database, _ event: JobEvent, to identity: JobIdentity, now: Date) throws -> UploadJob {
        guard let job = try fetch(db, identity: identity) else { throw StoreError.notFound("upload_job \(identity)") }
        var updated = try JobTransitions.apply(event, to: job, now: now)
        if updated != job { try save(db, &updated) }
        return updated
    }

    /// Narrowing (FR-06): cancels every job of the asset at the destination via `cancelAll`.
    @discardableResult
    public static func cancelAll(_ db: Database, assetKey: AssetKey, destinationId: DestinationID, now: Date) throws -> [UploadJob] {
        let jobs = try fetchAll(db, assetKey: assetKey).filter { $0.destinationId == destinationId }
        var changed = JobTransitions.cancelAll(jobs, now: now)
        for index in changed.indices { try save(db, &changed[index]) }
        return changed
    }

    /// Inserts (id nil) or updates by id; `id` is filled after an insert.
    public static func save(_ db: Database, _ job: inout UploadJob) throws {
        let values: [String: (any DatabaseValueConvertible)?] = [
            "destination_id": job.destinationId.rawValue, "asset_key": job.assetKey.rawValue,
            "res_type": job.resType.rawValue, "kind": job.kind.rawValue, "origin": job.origin.rawValue,
            "state": job.state.rawValue, "state_reason": job.stateReason?.rawValue,
            "remote_logical_parent": job.remoteLogicalParent, "remote_name": job.remoteName,
            "remote_id": job.remoteId, "session_ref": job.sessionRef, "session_md5": job.sessionMd5,
            "uploaded_hash": job.uploadedHash, "target_gen": job.targetGen, "done_gen": job.doneGen,
            "uploading_gen": job.uploadingGen, "mismatch_count": job.mismatchCount, "attempts": job.attempts,
            "next_attempt_at": job.nextAttemptAt, "deferred_since": job.deferredSince,
            "last_error": job.lastError, "updated_at": job.updatedAt, "backfill_run_id": job.backfillRunId,
        ]
        let arguments = StatementArguments(values.mapValues { $0?.databaseValue ?? .null })
        if let id = job.id {
            let assignments = values.keys.sorted().map { "\($0) = :\($0)" }.joined(separator: ", ")
            var all = arguments
            all += ["id": id]
            try db.execute(sql: "UPDATE upload_job SET \(assignments) WHERE id = :id", arguments: all)
        } else {
            let columns = values.keys.sorted()
            try db.execute(
                sql: "INSERT INTO upload_job (\(columns.joined(separator: ", "))) VALUES (\(columns.map { ":\($0)" }.joined(separator: ", ")))",
                arguments: arguments)
            job.id = db.lastInsertedRowID
        }
    }

    // MARK: Queries

    public static func fetch(_ db: Database, identity: JobIdentity) throws -> UploadJob? {
        try Row.fetchOne(db, sql: """
            SELECT * FROM upload_job WHERE destination_id = ? AND asset_key = ? AND res_type = ?
            """, arguments: [identity.destinationId.rawValue, identity.assetKey.rawValue, identity.resType.rawValue])
            .map(decode)
    }

    public static func fetchAll(_ db: Database, assetKey: AssetKey) throws -> [UploadJob] {
        try Row.fetchAll(db, sql: "SELECT * FROM upload_job WHERE asset_key = ? ORDER BY id", arguments: [assetKey.rawValue])
            .map(decode)
    }

    public static func fetch(_ db: Database, state: JobState, destinationId: DestinationID? = nil) throws -> [UploadJob] {
        try Row.fetchAll(db, sql: """
            SELECT * FROM upload_job WHERE state = ? AND (? IS NULL OR destination_id = ?) ORDER BY id
            """, arguments: [state.rawValue, destinationId?.rawValue, destinationId?.rawValue]).map(decode)
    }

    public static func count(_ db: Database, destinationId: DestinationID, state: JobState) throws -> Int {
        try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM upload_job WHERE destination_id = ? AND state = ?",
            arguments: [destinationId.rawValue, state.rawValue]) ?? 0
    }

    /// Pending, due jobs whose resource is staged at the target generation (sidecars need none),
    /// by origin priority then newest asset first. SQL narrows the candidates; `isReady` decides.
    public static func readyToUpload(
        _ db: Database, destinationId: DestinationID, now: Date, limit: Int
    ) throws -> [ReadyJob] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT j.* FROM upload_job j
            LEFT JOIN resource r ON r.asset_key = j.asset_key AND r.res_type = j.res_type
            LEFT JOIN asset a ON a.asset_key = j.asset_key
            WHERE j.destination_id = :destination AND j.state = 'pending'
              AND (j.next_attempt_at IS NULL OR j.next_attempt_at <= :now)
              AND (j.res_type IN (1001, 1002) OR (r.staging_state = 'ready' AND r.staging_gen >= j.target_gen))
            ORDER BY CASE j.origin
                    WHEN 'incremental' THEN 0 WHEN 'refresh' THEN 1 WHEN 'reupload' THEN 2
                    WHEN 'backfill' THEN 3 ELSE 4 END,
                a.creation_date DESC, j.id
            LIMIT :limit
            """, arguments: ["destination": destinationId.rawValue, "now": now, "limit": limit])
        var ready: [ReadyJob] = []
        for row in rows {
            let job = try decode(row)
            let resource = job.resType.isSidecar ? nil : try ResourceRepository.fetch(db, key: job.assetKey, type: job.resType)
            if JobTransitions.isReady(job, resource: resource, now: now) {
                ready.append(ReadyJob(job: job, resource: resource))
            }
        }
        return ready
    }

    static func decode(_ row: Row) throws -> UploadJob {
        let table = "upload_job"
        var job = UploadJob(
            id: row["id"],
            destinationId: try row.destinationId("destination_id", table: table),
            assetKey: try row.assetKey("asset_key", table: table),
            resType: try row.parse("res_type", table: table) { (raw: Int) in ResourceType(rawValue: raw) },
            origin: try row.enumValue("origin", table: table),
            state: try row.enumValue("state", table: table),
            stateReason: try row.optionalEnum("state_reason", table: table),
            remoteLogicalParent: row["remote_logical_parent"],
            remoteName: row["remote_name"],
            remoteId: row["remote_id"],
            sessionRef: row["session_ref"],
            sessionMd5: row["session_md5"],
            uploadedHash: row["uploaded_hash"],
            targetGen: row["target_gen"],
            doneGen: row["done_gen"],
            uploadingGen: row["uploading_gen"],
            mismatchCount: row["mismatch_count"],
            attempts: row["attempts"],
            nextAttemptAt: row["next_attempt_at"],
            deferredSince: row["deferred_since"],
            lastError: row["last_error"],
            updatedAt: try row.require("updated_at", table: table),
            backfillRunId: row["backfill_run_id"])
        job.kind = try row.enumValue("kind", table: table)
        return job
    }
}
