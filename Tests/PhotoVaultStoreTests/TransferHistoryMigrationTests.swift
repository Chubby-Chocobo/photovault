import Foundation
import GRDB
import PhotoVaultCore
import Testing
@testable import PhotoVaultStore

@Suite struct TransferHistoryMigrationTests {
    /// A database as the previous release left it: done, failed and open jobs of every origin.
    private func olderDatabase() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        let migrator = Schema.makeMigrator()
        try migrator.migrate(queue, upTo: "v7-import-retry")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO asset (asset_key, asset_key_hash, local_id, media_type, first_seen_at, last_seen_at) VALUES
                    ('l:a', 'ha', 'a', 1, ?1, ?1), ('l:b', 'hb', 'b', 1, ?1, ?1), ('l:c', 'hc', 'c', 1, ?1, ?1), ('l:d', 'hd', 'd', 1, ?1, ?1)
                """, arguments: [t0])
            try db.execute(sql: """
                INSERT INTO resource (asset_key, res_type, kind, original_filename, uti, size_bytes) VALUES
                    ('l:a', 1, 'original', 'IMG_A.HEIC', 'public.heic', 100), ('l:b', 1, 'original', 'IMG_B.HEIC', 'public.heic', 200),
                    ('l:c', 1, 'original', 'IMG_C.HEIC', 'public.heic', 300), ('l:d', 1, 'original', 'IMG_D.HEIC', 'public.heic', 400)
                """)
            try db.execute(sql: """
                INSERT INTO upload_job (destination_id, asset_key, res_type, kind, origin, state, done_gen, updated_at) VALUES
                    ('gdrive', 'l:a', 1, 'original', 'incremental', 'done', 1, ?1),
                    ('gdrive', 'l:b', 1, 'original', 'backfill', 'done', 1, ?2),
                    ('gdrive', 'l:c', 1, 'original', 'backfill', 'pending', 0, ?3),
                    ('gdrive', 'l:d', 1, 'original', 'backfill', 'skipped', 0, ?3),
                    ('gdrive', 'l:a', 1001, 'sidecarJson', 'incremental', 'done', 1, ?1)
                """, arguments: [t0, t0.addingTimeInterval(10), t0.addingTimeInterval(20)])
        }
        return queue
    }

    @Test func doneJobsBecomeApproximateUploadsAndOldBackfillJobsShareOneRun() throws {
        let queue = try olderDatabase()
        try Schema.makeMigrator().migrate(queue)
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM transfer_event ORDER BY at")
            #expect(rows.map { $0["asset_key"] as String } == ["l:a", "l:b"])
            #expect(rows.allSatisfy { $0["approximate"] == true && $0["outcome"] == "uploaded" })
            #expect(rows.map { $0["bytes"] as Int64 } == [100, 200])
            #expect((rows.first?["at"] as Date?) == t0)
            let run = try #require(try Row.fetchOne(db, sql: "SELECT * FROM backfill_run"))
            #expect(run["trigger"] == "beforeHistory" && run["approximate"] == true)
            #expect((run["started_at"] as Date?) == t0.addingTimeInterval(10))
            #expect(run["finished_at"] as Date? == nil, "a job of the run still waits")
            let runId: Int64 = run["id"]
            #expect(rows.last?["run_id"] == runId)
            let members = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM upload_job WHERE backfill_run_id = ?", arguments: [runId])
            #expect(members == 3)
        }
    }

    @Test func seedingAgainChangesNothing() throws {
        let queue = try olderDatabase()
        try Schema.makeMigrator().migrate(queue)
        func snapshot(_ db: Database) throws -> [String] {
            try Row.fetchAll(db, sql: "SELECT * FROM transfer_event ORDER BY id").map(\.description)
                + Row.fetchAll(db, sql: "SELECT * FROM backfill_run ORDER BY id").map(\.description)
                + Row.fetchAll(db, sql: "SELECT id, backfill_run_id FROM upload_job ORDER BY id").map(\.description)
        }
        let before = try queue.read(snapshot)
        try queue.write { db in try Schema.seedTransferHistory(db) }
        #expect(try queue.read(snapshot) == before)
    }

    @Test func aNewDatabaseStartsEmptyAndRecordsFromThenOn() throws {
        let store = try Store.inMemory()
        let counts = try store.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transfer_event"), try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM backfill_run"))
        }
        #expect(counts.0 == 0 && counts.1 == 0)
    }

    @Test func theMigrationOnlyAdds() throws {
        let queue = try olderDatabase()
        let before = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT name, sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name").map { row in
                "\(row["name"] as String): \(row["sql"] as String)"
            }
        }
        try Schema.makeMigrator().migrate(queue)
        let after = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT name, sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name").map { row in
                "\(row["name"] as String): \(row["sql"] as String)"
            }
        }
        let changed = before.filter { !after.contains($0) }
        // Only `upload_job` gains a column; every other object is untouched.
        #expect(changed.count == 1 && changed.first?.hasPrefix("upload_job: CREATE TABLE upload_job") == true, "\(changed)")
        try queue.read { db in
            let jobs = try Row.fetchAll(db, sql: "SELECT state, origin, done_gen FROM upload_job ORDER BY id").map(\.description)
            #expect(jobs.count == 5)
        }
    }
}
