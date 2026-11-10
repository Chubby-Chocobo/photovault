import Foundation
import GRDB
import PhotoVaultCore
import Testing
@testable import PhotoVaultStore

private let day1 = ArchiveDay(year: 2026, month: 11, day: 8)!
private let day2 = ArchiveDay(year: 2026, month: 11, day: 9)!

@Suite struct DayPlaceMigrationTests {
    @Test func upgradeKeepsAssetsWithoutSlots() async throws {
        let queue = try DatabaseQueue()
        let migrator = Schema.makeMigrator()
        try migrator.migrate(queue, upTo: "v5-sources")
        try await queue.write { db in
            for id in ["A", "B"] { try AssetRepository.upsertLegacyRowForMigrationTest(db, id) }
        }
        try migrator.migrate(queue)
        try await queue.read { db in
            let assets = try Row.fetchAll(db, sql: "SELECT * FROM asset").map(AssetRepository.decode)
            #expect(assets.count == 2)
            #expect(assets.allSatisfy { $0.placeSlot == nil })
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM day_place") == 0)
            let indexes = try Set(Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'").map { $0["name"] as String })
            #expect(indexes.contains("move_job_subject"))
        }
    }
}

@Suite struct PlaceSlotTests {
    @Test func upsertKeepsSlotSetBySetter() throws {
        let store = try Store.inMemory()
        let asset = makeAsset("A")
        try store.write { db in
            try AssetRepository.upsert(db, asset, timeZone: utc)
            try AssetPlacementRepository.setPlaceSlot(db, key: asset.assetKey, slot: "p3f9a1c2e4b5d")
            try AssetRepository.upsert(db, asset, timeZone: utc)
        }
        let slot = try store.read { try AssetRepository.fetch($0, key: asset.assetKey)?.placeSlot }
        #expect(slot == "p3f9a1c2e4b5d")
    }

    @Test func clearPlaceSlotsResetsEveryAsset() throws {
        let store = try Store.inMemory()
        try store.write { db in
            for id in ["A", "B"] {
                let asset = makeAsset(id)
                try AssetRepository.upsert(db, asset, timeZone: utc)
                try AssetPlacementRepository.setPlaceSlot(db, key: asset.assetKey, slot: "pabc")
            }
            try AssetPlacementRepository.setPlaceSlot(db, key: .local("A"), slot: nil)
        }
        #expect(try store.read { try AssetRepository.fetch($0, key: .local("A"))?.placeSlot } == nil)
        try store.write { try AssetPlacementRepository.clearPlaceSlots($0) }
        #expect(try store.read { try AssetRepository.fetch($0, key: .local("B"))?.placeSlot } == nil)
    }

    @Test func recordCodableRoundTripsWithAndWithoutSlot() throws {
        var asset = makeAsset("A")
        let plain = try JSONDecoder().decode(AssetRecord.self, from: JSONEncoder().encode(asset))
        #expect(plain.placeSlot == nil)
        asset.placeSlot = "pabc"
        let slotted = try JSONDecoder().decode(AssetRecord.self, from: JSONEncoder().encode(asset))
        #expect(slotted == asset)
    }
}

@Suite struct DayPlaceRepositoryTests {
    @Test func saveUpdateFetchOrderDaysAndDelete() throws {
        let store = try Store.inMemory()
        try store.write { db in
            try DayPlaceRepository.save(db, DayPlace(day: day1, slot: "pb", placeKey: "VN|Ninh Bình", placeName: "Ninh Bình"))
            try DayPlaceRepository.save(db, DayPlace(day: day1, slot: "pa", placeKey: nil, placeName: nil))
            try DayPlaceRepository.save(db, DayPlace(day: day2, slot: "pc", placeKey: "VN|Đà Nẵng", placeName: "Đà Nẵng"))
            try DayPlaceRepository.save(db, DayPlace(day: day1, slot: "pa", placeKey: "VN|Lào Cai", placeName: "Lào Cai"))
        }
        try store.read { db in
            let rows = try DayPlaceRepository.fetchAll(db, day: day1)
            #expect(rows.map(\.slot) == ["pa", "pb"])
            #expect(rows[0].placeName == "Lào Cai")
            #expect(rows[1].placeName == "Ninh Bình")
            #expect(rows[1].placeKey == "VN|Ninh Bình")
            #expect(try DayPlaceRepository.exists(db, day: day1))
            #expect(try DayPlaceRepository.days(db) == [day1, day2])
            #expect(try !DayPlaceRepository.exists(db, day: ArchiveDay(year: 2026, month: 1, day: 1)!))
        }
        try store.write { try DayPlaceRepository.deleteAll($0) }
        let remaining = try store.read { try DayPlaceRepository.days($0) }
        #expect(remaining.isEmpty)
    }
}

@Suite struct NewerSchemaGuardTests {
    private func future() -> DatabaseMigrator {
        var migrator = Schema.makeMigrator()
        migrator.registerMigration("v99-future") { try $0.execute(sql: "CREATE TABLE future_thing (id INTEGER)") }
        return migrator
    }

    @Test func refusesDatabaseWithUnknownMigration() throws {
        let dir = try tempDirectory()
        let url = dir.appendingPathComponent("db.sqlite")
        let schema = "SELECT name FROM sqlite_master ORDER BY name"
        let original = try Store.open(at: url, backups: nil, migrator: future())
        let before = try original.read { try String.fetchAll($0, sql: schema) }
        #expect(throws: StoreError.newerSchema) { try Store.open(at: url) }
        #expect(try original.read { try String.fetchAll($0, sql: schema) } == before)
        #expect(!DatabaseBackup.isCorruption(StoreError.newerSchema))
    }

    @Test func currentSchemaStillOpensTwice() throws {
        let url = try tempDirectory().appendingPathComponent("db.sqlite")
        _ = try Store.open(at: url)
        _ = try Store.open(at: url)
    }
}
