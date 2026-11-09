import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Recovered local files are verified in the background (8.15, local): the SHA-256 of the file on
/// disk is compared with the hash the sidecar recorded. A few files per cycle keep the NAS calm.
/// A file that is gone or differs becomes `missingRemote`; one without a recorded hash gets it now.
enum RecoveryVerifier {
    static let cursorKey = "recovery_verify_cursor:"
    static let limitKey = "recovery_verify_limit:"

    /// Verifies the done jobs that exist now.
    static func schedule(_ db: Database, destinationId: DestinationID) throws {
        let limit = try Int64.fetchOne(db, sql: """
            SELECT MAX(id) FROM upload_job WHERE destination_id = ? AND state = 'done' AND remote_id IS NOT NULL
            """, arguments: [destinationId.rawValue])
        try KeyValueRepository.set(db, cursorKey + destinationId.rawValue, 0)
        try KeyValueRepository.set(db, limitKey + destinationId.rawValue, limit)
    }
}

struct RecoveryVerifyStage: CycleStage {
    let env: EngineEnvironment
    var step: CycleStep { .cloudIds }

    func run(trigger: SyncTrigger) async throws -> Bool {
        guard let reader = env.localContent else { return false }
        let pending: [(DestinationID, Int64, Int64)] = try await env.store.read { db in
            try DestinationRepository.fetchAll(db).compactMap { record in
                guard let limit = try KeyValueRepository.int(db, RecoveryVerifier.limitKey + record.id.rawValue) else { return nil }
                let cursor = try KeyValueRepository.int(db, RecoveryVerifier.cursorKey + record.id.rawValue) ?? 0
                return (record.id, Int64(cursor), Int64(limit))
            }
        }
        var worked = false
        for (id, cursor, limit) in pending {
            guard await env.destinations.destination(for: id) != nil else { continue }
            worked = try await verify(id, after: cursor, limit: limit, reader: reader) || worked
        }
        return worked
    }

    private func verify(_ id: DestinationID, after cursor: Int64, limit: Int64, reader: any LocalContentReading) async throws -> Bool {
        let rows: [(Int64, JobIdentity, String, String?)] = try await env.store.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, asset_key, res_type, remote_id, uploaded_hash FROM upload_job
                WHERE destination_id = ? AND state = 'done' AND remote_id IS NOT NULL AND id > ? AND id <= ? ORDER BY id LIMIT ?
                """, arguments: [id.rawValue, cursor, limit, env.tuning.recoveryVerifyBatch]).compactMap { row in
                guard let key = AssetKey(rawValue: row["asset_key"]) else { return nil }
                return (row["id"], JobIdentity(destinationId: id, assetKey: key, resType: ResourceType(rawValue: row["res_type"])),
                        row["remote_id"], row["uploaded_hash"])
            }
        }
        guard !rows.isEmpty else {
            try await env.store.write { db in
                try KeyValueRepository.set(db, RecoveryVerifier.cursorKey + id.rawValue, nil)
                try KeyValueRepository.set(db, RecoveryVerifier.limitKey + id.rawValue, nil)
            }
            return false
        }
        var lastDone = cursor
        for (jobId, identity, path, expected) in rows {
            let actual: String?
            do {
                actual = try await reader.sha256(destination: id, path: path)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                env.log.log(.notice, category: "recovery", "verify paused type=\(type(of: error))")
                break
            }
            try await settle(identity, actual: actual, expected: expected)
            lastDone = jobId
        }
        let progressed = lastDone
        try await env.store.write { db in try KeyValueRepository.set(db, RecoveryVerifier.cursorKey + id.rawValue, progressed) }
        return true
    }

    private func settle(_ identity: JobIdentity, actual: String?, expected: String?) async throws {
        let now = env.clock.now
        try await env.store.write { db in
            if let actual, expected == nil {
                try db.execute(sql: """
                    UPDATE upload_job SET uploaded_hash = ? WHERE destination_id = ? AND asset_key = ? AND res_type = ?
                    """, arguments: [actual, identity.destinationId.rawValue, identity.assetKey.rawValue, identity.resType.rawValue])
            } else if actual == nil || actual != expected {
                // Only a file still recorded as uploaded is reported; a job that moved on meanwhile
                // (a new edit being sent) is left to its own upload.
                guard try JobRepository.fetch(db, identity: identity)?.state == .done else { return }
                do {
                    _ = try JobRepository.apply(db, .missingAtDestination, to: identity, now: now)
                } catch is JobTransitionError {
                    return
                }
                try ActivityRepository.record(db, ActivityEvent(
                    at: now, kind: .missingFile, destinationId: identity.destinationId, assetKey: identity.assetKey,
                    message: actual == nil ? "Một file đã khôi phục không còn ở đích" : "Một file đã khôi phục có nội dung khác với sidecar"))
            }
        }
    }
}
