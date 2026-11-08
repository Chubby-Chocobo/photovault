import Foundation
import GRDB
import PhotoVaultCore
import Testing
@testable import PhotoVaultStore

@Suite struct DatabaseBackupTests {
    private func fixture() throws -> (dir: URL, db: URL, store: Store, backup: DatabaseBackup) {
        let dir = try tempDirectory()
        let db = dir.appendingPathComponent("db/photovault.sqlite")
        let backup = DatabaseBackup(directory: dir.appendingPathComponent("backups"))
        return (dir, db, try Store.open(at: db, backups: backup), backup)
    }

    @Test func keepsSevenNewest() throws {
        let f = try fixture()
        for i in 0..<10 { try f.backup.backup(f.store, now: t0.addingTimeInterval(Double(i) * 3600)) }
        let names = try f.backup.existingBackups().map(\.lastPathComponent)
        #expect(names.count == 7)
        #expect(names.first == DatabaseBackup.fileName(for: t0.addingTimeInterval(9 * 3600)))
        #expect(names.last == DatabaseBackup.fileName(for: t0.addingTimeInterval(3 * 3600)))
    }

    @Test func dueOnlyAfter24Hours() throws {
        let f = try fixture()
        #expect(try f.backup.backupIfDue(f.store, now: t0) != nil)
        #expect(try f.backup.backupIfDue(f.store, now: t0.addingTimeInterval(23 * 3600)) == nil)
        #expect(try f.backup.backupIfDue(f.store, now: t0.addingTimeInterval(24 * 3600)) != nil)
        #expect(try f.backup.existingBackups().count == 2)
    }

    @Test func backupIsAReadableCopy() throws {
        let f = try fixture()
        try f.store.write { try AssetRepository.upsert($0, makeAsset("A"), timeZone: utc) }
        let url = try f.backup.backup(f.store, now: t0)
        let copy = try DatabaseQueue(path: url.path)
        #expect(try copy.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM asset") } == 1)
    }

    @Test func restoreNewestMarksEveryDestinationRecoveryRequired() throws {
        let f = try fixture()
        try f.store.write { db in
            _ = try DestinationRepository.add(db, makeDestination(), now: t0)
            _ = try DestinationRepository.add(db, makeDestination(.local()), now: t0)
            try AssetRepository.upsert(db, makeAsset("A"), timeZone: utc)
        }
        try f.backup.backup(f.store, now: t0)
        // Corrupt the live database.
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: f.db.path + suffix) }
        try Data("garbage".utf8).write(to: f.db)

        #expect(throws: (any Error).self) { try Store.open(at: f.db) }
        let restored = try #require(try f.backup.restoreNewest(to: f.db))
        let destinations = try restored.read { try DestinationRepository.fetchAll($0) }
        #expect(destinations.count == 2 && destinations.allSatisfy(\.recoveryRequired))
        #expect(try restored.read { try AssetRepository.count($0) } == 1)
    }

    @Test func restoreWithoutBackupsReturnsNil() throws {
        let dir = try tempDirectory()
        let backup = DatabaseBackup(directory: dir.appendingPathComponent("none"))
        #expect(try backup.restoreNewest(to: dir.appendingPathComponent("db.sqlite")) == nil)
    }

    @Test func backsUpBeforePendingMigration() throws {
        let f = try fixture()
        #expect(try f.backup.existingBackups().isEmpty, "fresh database has nothing to protect")
        var migrator = Schema.makeMigrator()
        migrator.registerMigration("v2") { try $0.execute(sql: "CREATE TABLE extra (id INTEGER)") }
        let reopened = try Store.open(at: f.db, backups: f.backup, migrator: migrator)
        #expect(try f.backup.existingBackups().count == 1)
        #expect(try reopened.read { try $0.tableExists("extra") })
        // Already migrated: no further backup.
        _ = try Store.open(at: f.db, backups: f.backup, migrator: migrator)
        #expect(try f.backup.existingBackups().count == 1)
    }
}
