import Foundation
import GRDB
import PhotoVaultCore
import Testing
@testable import PhotoVaultStore

@Suite struct SnapshotCounterTests {
    private static let states = ["pending", "uploading", "done", "deferred", "skipped", "missingRemote", "cancelled"]
    private static let origins = ["incremental", "backfill", "destinationBackfill", "refresh", "reupload"]
    private let nas = "local-\(UUID().uuidString)"

    /// Batched inserts of assets × resources × destinations with a spread of states and origins.
    private func fill(_ db: Database, assets: Int) throws {
        let now = Date()
        let destinations = ["gdrive", nas]
        let asset = try db.makeStatement(sql: """
            INSERT INTO asset (asset_key, asset_key_hash, local_id, media_type, first_seen_at, last_seen_at) VALUES (?, ?, ?, 1, ?, ?)
            """)
        let resource = try db.makeStatement(sql: """
            INSERT INTO resource (asset_key, res_type, kind, original_filename, uti, size_bytes) VALUES (?, ?, 'original', 'IMG.HEIC', 'public.heic', ?)
            """)
        let job = try db.makeStatement(sql: """
            INSERT INTO upload_job (destination_id, asset_key, res_type, kind, origin, state, updated_at) VALUES (?, ?, ?, 'original', ?, ?, ?)
            """)
        for i in 0..<assets {
            let key = "l:a\(i)"
            try asset.execute(arguments: [key, "h\(i)", "a\(i)", now, now])
            for type in [1, 9] {
                try resource.execute(arguments: [key, type, 1_000 + i])
                for (n, destination) in destinations.enumerated() {
                    try job.execute(arguments: [
                        destination, key, type, Self.origins[(i + n) % Self.origins.count], Self.states[(i + type + n) % Self.states.count], now,
                    ])
                }
            }
        }
    }

    private func expectCountersMatchTables(_ db: Database) throws {
        let counted = try SnapshotCounterRepository.jobCounts(db)
        var oracle: [DestinationID: [JobState: Int]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT destination_id, state, COUNT(*) AS n FROM upload_job GROUP BY destination_id, state") {
            let destination = try #require(DestinationID(rawValue: row["destination_id"]))
            oracle[destination, default: [:]][try #require(JobState(rawValue: row["state"]))] = row["n"]
        }
        #expect(counted == oracle)
        let total = try Int.fetchOne(db, sql: """
            SELECT COUNT(DISTINCT asset_key) FROM upload_job WHERE origin IN ('backfill', 'destinationBackfill') AND state != 'cancelled'
            """) ?? 0
        let open = try Int.fetchOne(db, sql: """
            SELECT COUNT(DISTINCT asset_key) FROM upload_job
            WHERE origin IN ('backfill', 'destinationBackfill') AND state IN ('pending', 'uploading', 'deferred', 'missingRemote')
            """) ?? 0
        let progress = try SnapshotCounterRepository.backfillProgress(db)
        #expect(progress.total == total)
        #expect(progress.done == total - open)
        let bytes = try Int64.fetchOne(db, sql: """
            SELECT COALESCE(SUM(r.size_bytes), 0) FROM upload_job j
            JOIN resource r ON r.asset_key = j.asset_key AND r.res_type = j.res_type WHERE j.state = 'done'
            """) ?? 0
        #expect(try SnapshotCounterRepository.uploadedBytes(db) == bytes)
    }

    @Test func countersFollowInsertsUpdatesAndDeletes() async throws {
        let store = try Store.inMemory()
        let nas = nas
        try await store.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try fill(db, assets: 2_000)
            try expectCountersMatchTables(db)
            try db.execute(sql: "UPDATE upload_job SET state = 'done' WHERE id % 7 = 0")
            try db.execute(sql: "UPDATE upload_job SET state = 'pending' WHERE id % 11 = 0 AND state = 'done'")
            try db.execute(sql: "UPDATE upload_job SET origin = 'reupload' WHERE id % 13 = 0")
            try db.execute(sql: "UPDATE upload_job SET state = 'cancelled' WHERE origin = 'backfill' AND id % 3 = 0")
            try db.execute(sql: "UPDATE upload_job SET asset_key = 'l:moved' WHERE id = 5")
            try expectCountersMatchTables(db)
            try db.execute(sql: "DELETE FROM upload_job WHERE destination_id = ?", arguments: [nas])
            try expectCountersMatchTables(db)
            try db.execute(sql: "DELETE FROM upload_job")
            try expectCountersMatchTables(db)
            #expect(try SnapshotCounterRepository.backfillProgress(db) == (0, 0))
        }
    }

    @Test func migrationBuildsCountersFromExistingJobs() async throws {
        let queue = try DatabaseQueue()
        let migrator = Schema.makeMigrator()
        try migrator.migrate(queue, upTo: "v2-upload-intent")
        try await queue.write { [self] db in try fill(db, assets: 500) }
        try migrator.migrate(queue)
        try await queue.read { [self] db in try expectCountersMatchTables(db) }
    }

    @Test func snapshotQueriesDoNotScanTheJobTable() async throws {
        let store = try Store.inMemory()
        try await store.read { db in
            let queries = [
                "SELECT destination_id, state, n FROM job_count WHERE n > 0",
                "SELECT COUNT(*) FROM backfill_asset",
                "SELECT COUNT(*) FROM backfill_asset WHERE open > 0",
                "SELECT value FROM snapshot_counter WHERE name = 'uploaded_bytes'",
            ]
            for sql in queries {
                let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).map { $0["detail"] as String }.joined(separator: " | ")
                #expect(!plan.contains("upload_job"), "\(sql): \(plan)")
            }
        }
    }
}
