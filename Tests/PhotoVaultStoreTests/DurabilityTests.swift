import Foundation
import GRDB
import PhotoVaultCore
import Testing
@testable import PhotoVaultStore

/// NFR-01: a power loss or kernel panic must not drop a committed reservation.
@Suite struct DurabilityTests {
    @Test func everyConnectionIsFullySynchronous() throws {
        let dir = try tempDirectory()
        let store = try Store.open(at: dir.appendingPathComponent("db/photovault.sqlite"))
        func pragmas(_ db: Database) throws -> [Int] {
            try ["synchronous", "fullfsync", "checkpoint_fullfsync"].map { try Int.fetchOne(db, sql: "PRAGMA \($0)") ?? -1 }
        }
        // synchronous FULL = 2
        let written = try store.write(pragmas)
        #expect(written == [2, 1, 1], "\(written)")
        #expect(try store.read(pragmas) == [2, 1, 1])
    }
}

@Suite struct UploadIntentTests {
    @Test func migrationAddsTheIntentTableToADatabaseCreatedBeforeIt() throws {
        let dir = try tempDirectory()
        let url = dir.appendingPathComponent("db/photovault.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A database that has run only the first migration and holds a job.
        let queue = try DatabaseQueue(path: url.path)
        var first = DatabaseMigrator()
        first.registerMigration("v1") { try Schema.createV1($0) }
        try first.migrate(queue)
        try queue.write { db in
            _ = try DestinationRepository.add(db, makeDestination(.googleDrive), now: t0)
        }
        try queue.close()

        let store = try Store.open(at: url)
        let tables = try store.read { try String.fetchSet($0, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") }
        #expect(tables.contains("upload_intent"))
        #expect(try store.read { try DestinationRepository.fetchAll($0) }.count == 1, "existing data is untouched")
    }

    @Test func intentIsSavedReplacedAndDeleted() throws {
        let store = try Store.inMemory()
        let intent = UploadIntent(jobId: 7, destinationId: .local(), remotePath: "2026/10/a.HEIC", contentSha256: "aa", createdAt: t0)
        try store.write { try UploadIntentRepository.save($0, intent) }
        #expect(try store.read { try UploadIntentRepository.fetch($0, jobId: 7) } == intent)
        var replanned = intent
        replanned.remotePath = "2026/10/23/a.HEIC"
        replanned.contentSha256 = "bb"
        try store.write { try UploadIntentRepository.save($0, replanned) }
        #expect(try store.read { try UploadIntentRepository.fetch($0, jobId: 7) } == replanned)
        try store.write { try UploadIntentRepository.delete($0, jobId: 7) }
        #expect(try store.read { try UploadIntentRepository.fetch($0, jobId: 7) } == nil)
    }

    @Test func removingADestinationOrResettingItDropsItsIntents() throws {
        let store = try Store.inMemory()
        let nas = DestinationID.local()
        try store.write { db in
            _ = try DestinationRepository.add(db, makeDestination(.googleDrive), now: t0)
            _ = try DestinationRepository.add(db, makeDestination(nas), now: t0)
            try UploadIntentRepository.save(db, UploadIntent(jobId: 1, destinationId: nas, remotePath: "a", contentSha256: "x", createdAt: t0))
            try UploadIntentRepository.save(db, UploadIntent(jobId: 2, destinationId: .googleDrive, remotePath: "b", contentSha256: "y", createdAt: t0))
            try DestinationRepository.resetState(db, id: nas)
        }
        #expect(try store.read { try UploadIntentRepository.fetch($0, jobId: 1) } == nil)
        #expect(try store.read { try UploadIntentRepository.fetch($0, jobId: 2) } != nil)
    }
}
