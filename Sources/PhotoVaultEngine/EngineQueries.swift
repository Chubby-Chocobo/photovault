import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Read queries and small updates the Store repositories do not offer. Plain SQL against the
/// schema; every function runs inside the caller's transaction.
enum EngineQueries {
    // MARK: Assets

    static func unplacedFinalAssetKeys(_ db: Database, limit: Int) throws -> [AssetKey] {
        try String.fetchAll(db, sql: """
            SELECT asset_key FROM asset
            WHERE placement_category IS NULL AND category IS NOT NULL AND category_provisional = 0 AND deleted_at IS NULL
            ORDER BY asset_key LIMIT ?
            """, arguments: [limit]).compactMap(AssetKey.init(rawValue:))
    }

    static func provisionalAssetKeys(_ db: Database, limit: Int) throws -> [AssetKey] {
        try String.fetchAll(db, sql: """
            SELECT asset_key FROM asset WHERE category_provisional = 1 AND deleted_at IS NULL
            ORDER BY (inserted_at IS NULL), creation_date DESC LIMIT ?
            """, arguments: [limit]).compactMap(AssetKey.init(rawValue:))
    }

    static func liveAssetKeys(_ db: Database, after key: String, limit: Int) throws -> [AssetKey] {
        try String.fetchAll(db, sql: """
            SELECT asset_key FROM asset WHERE deleted_at IS NULL AND asset_key > ? ORDER BY asset_key LIMIT ?
            """, arguments: [key, limit]).compactMap(AssetKey.init(rawValue:))
    }

    static func localIdIndex(_ db: Database) throws -> [String: AssetKey] {
        var index: [String: AssetKey] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT local_id, asset_key FROM asset") {
            if let key = AssetKey(rawValue: row["asset_key"]) { index[row["local_id"]] = key }
        }
        return index
    }

    static func assetKeysWithAlbums(_ db: Database) throws -> Set<AssetKey> {
        Set(try String.fetchAll(db, sql: "SELECT DISTINCT asset_key FROM album_member").compactMap(AssetKey.init(rawValue:)))
    }

    /// Counts the `camera` assets of a day that are in scope of the global switches (FR-19, 8.7).
    static func recountDay(_ db: Database, day: ArchiveDay, settings: GlobalSettings) throws {
        let text = day.description
        let count = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM asset
            WHERE category = 'camera' AND deleted_at IS NULL
              AND (placement_day = :day OR (placement_day IS NULL AND creation_day = :day))
              AND (:hidden = 1 OR is_hidden = 0)
              AND (:bursts = 1 OR burst_identifier IS NULL OR burst_is_pick = 1)
              AND (:videos = 1 OR media_type != 2)
            """, arguments: [
                "day": text, "hidden": settings.includeHidden, "bursts": settings.includeAllBurstFrames,
                "videos": settings.includeVideos,
            ]) ?? 0
        try db.execute(sql: """
            INSERT INTO day_stat (day, count) VALUES (?, ?) ON CONFLICT(day) DO UPDATE SET count = excluded.count
            """, arguments: [text, count])
    }

    // MARK: Resources

    static func stagedBytes(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(size_bytes), 0) FROM resource WHERE staging_state = 'ready'") ?? 0
    }

    /// Resets an export that ended without being counted as an error (cancelled by a rule or by
    /// shutdown): `exporting → none`.
    static func resetExportToNone(_ db: Database, key: AssetKey, type: ResourceType) throws {
        try db.execute(sql: """
            UPDATE resource SET staging_state = 'none', staging_path = NULL
            WHERE asset_key = ? AND res_type = ? AND staging_state = 'exporting'
            """, arguments: [key.rawValue, type.rawValue])
    }

    static func clearExportFailures(_ db: Database, key: AssetKey, type: ResourceType) throws {
        try db.execute(sql: """
            UPDATE resource SET export_attempts = 0, export_deferred_since = NULL, next_export_attempt_at = NULL
            WHERE asset_key = ? AND res_type = ?
            """, arguments: [key.rawValue, type.rawValue])
    }

    static func clearTooLarge(_ db: Database, key: AssetKey, type: ResourceType) throws {
        try db.execute(sql: """
            UPDATE resource SET too_large_for_disk = 0, disk_cancel_count = 0, bytes_received_at_cancel = NULL,
                next_export_attempt_at = NULL
            WHERE asset_key = ? AND res_type = ?
            """, arguments: [key.rawValue, type.rawValue])
    }

    static func tooLargeResources(_ db: Database) throws -> [ResourceRecord] {
        let rows = try Row.fetchAll(db, sql: "SELECT asset_key, res_type FROM resource WHERE too_large_for_disk = 1")
        return try rows.compactMap { row in
            guard let key = AssetKey(rawValue: row["asset_key"]) else { return nil }
            return try ResourceRepository.fetch(db, key: key, type: ResourceType(rawValue: row["res_type"]))
        }
    }

    /// Number of live jobs at available destinations that can use the staged generation.
    static func jobsNeedingStaging(_ db: Database, key: AssetKey, type: ResourceType, stagingGen: Int) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM upload_job j JOIN destination d ON d.id = j.destination_id
            WHERE j.asset_key = ? AND j.res_type = ? AND j.state IN ('pending', 'uploading')
              AND j.target_gen <= ? AND d.status = 'active' AND d.recovery_required = 0
            """, arguments: [key.rawValue, type.rawValue, stagingGen]) ?? 0
    }

    /// Available destinations with a pending job for the resource.
    static func destinationsNeeding(_ db: Database, key: AssetKey, type: ResourceType) throws -> [DestinationRecord] {
        let ids = try String.fetchAll(db, sql: """
            SELECT DISTINCT d.id FROM upload_job j JOIN destination d ON d.id = j.destination_id
            WHERE j.asset_key = ? AND j.res_type = ? AND j.state = 'pending'
              AND d.status = 'active' AND d.recovery_required = 0
            """, arguments: [key.rawValue, type.rawValue])
        return try ids.compactMap { raw in
            try DestinationID(rawValue: raw).flatMap { try DestinationRepository.fetch(db, id: $0) }
        }
    }

    struct ExportRow: Sendable {
        var key: AssetKey
        var type: ResourceType
        var priority: Int
        var creationDate: Date?
        var exportCount: Int
        var sizeBytes: Int64?
        var origins: Set<JobOrigin>
    }

    /// Resources some available destination is waiting for, ready to be exported (FR-30..34).
    static func exportCandidates(_ db: Database, now: Date, backfillAllowed: Bool, limit: Int) throws -> [ExportRow] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT r.asset_key, r.res_type, r.export_count, r.size_bytes, a.creation_date,
                   MIN(CASE j.origin WHEN 'incremental' THEN 0 WHEN 'refresh' THEN 1 WHEN 'reupload' THEN 2
                                      WHEN 'backfill' THEN 3 ELSE 4 END) AS prio,
                   GROUP_CONCAT(DISTINCT j.origin) AS origins
            FROM resource r
            JOIN asset a ON a.asset_key = r.asset_key
            JOIN upload_job j ON j.asset_key = r.asset_key AND j.res_type = r.res_type
            JOIN destination d ON d.id = j.destination_id
            WHERE r.staging_state = 'none' AND r.too_large_for_disk = 0
              AND a.placement_category IS NOT NULL AND a.deleted_at IS NULL
              AND (r.next_export_attempt_at IS NULL OR r.next_export_attempt_at <= :now)
              AND j.state = 'pending' AND j.target_gen <= r.content_gen
              AND d.status = 'active' AND d.recovery_required = 0
              AND (:backfill = 1 OR j.origin IN ('incremental', 'refresh'))
            GROUP BY r.asset_key, r.res_type
            ORDER BY prio, a.creation_date DESC, r.asset_key, r.res_type
            LIMIT :limit
            """, arguments: ["now": now, "backfill": backfillAllowed, "limit": limit])
        return rows.compactMap { row in
            guard let key = AssetKey(rawValue: row["asset_key"]) else { return nil }
            let origins = Set((row["origins"] as String? ?? "").split(separator: ",").compactMap { JobOrigin(rawValue: String($0)) })
            return ExportRow(
                key: key, type: ResourceType(rawValue: row["res_type"]), priority: row["prio"],
                creationDate: row["creation_date"], exportCount: row["export_count"], sizeBytes: row["size_bytes"], origins: origins)
        }
    }

    // MARK: Jobs

    static func jobs(_ db: Database, key: AssetKey, type: ResourceType, states: Set<JobState>) throws -> [UploadJob] {
        try JobRepository.fetchAll(db, assetKey: key).filter { $0.resType == type && states.contains($0.state) }
    }

    /// Applies `event` to every job in `states` for the resource; transitions that do not apply are skipped.
    static func apply(_ db: Database, _ event: JobEvent, key: AssetKey, type: ResourceType, states: Set<JobState>,
                      destinations: Set<DestinationID>? = nil, now: Date) throws {
        for job in try jobs(db, key: key, type: type, states: states) where destinations?.contains(job.destinationId) ?? true {
            _ = try? JobRepository.apply(db, event, to: job.identity, now: now)
        }
    }

    // MARK: Snapshot counts

    struct JobCounts: Sendable, Equatable {
        var pending = 0, uploading = 0, done = 0, deferred = 0, skipped = 0, missingRemote = 0, cancelled = 0
    }

    static func jobCounts(_ db: Database, destinationId: DestinationID?) throws -> JobCounts {
        var counts = JobCounts()
        let rows = try Row.fetchAll(db, sql: """
            SELECT state, COUNT(*) AS n FROM upload_job WHERE (? IS NULL OR destination_id = ?) GROUP BY state
            """, arguments: [destinationId?.rawValue, destinationId?.rawValue])
        for row in rows {
            let n: Int = row["n"]
            switch JobState(rawValue: row["state"]) {
            case .pending: counts.pending = n
            case .uploading: counts.uploading = n
            case .done: counts.done = n
            case .deferred: counts.deferred = n
            case .skipped: counts.skipped = n
            case .missingRemote: counts.missingRemote = n
            case .cancelled: counts.cancelled = n
            case nil: break
            }
        }
        return counts
    }

    /// (assets with backfill jobs, of which finished) for the progress display.
    static func backfillProgress(_ db: Database) throws -> (done: Int, total: Int) {
        let total = try Int.fetchOne(db, sql: """
            SELECT COUNT(DISTINCT asset_key) FROM upload_job
            WHERE origin IN ('backfill', 'destinationBackfill') AND state != 'cancelled'
            """) ?? 0
        let open = try Int.fetchOne(db, sql: """
            SELECT COUNT(DISTINCT asset_key) FROM upload_job
            WHERE origin IN ('backfill', 'destinationBackfill') AND state IN ('pending', 'uploading', 'deferred', 'missingRemote')
            """) ?? 0
        return (total - open, total)
    }

    static func uploadedBytes(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: """
            SELECT COALESCE(SUM(r.size_bytes), 0) FROM upload_job j
            JOIN resource r ON r.asset_key = j.asset_key AND r.res_type = j.res_type WHERE j.state = 'done'
            """) ?? 0
    }
}
