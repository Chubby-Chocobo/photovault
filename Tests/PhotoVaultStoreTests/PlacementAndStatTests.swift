import Foundation
import GRDB
import PhotoVaultCore
import Testing
@testable import PhotoVaultStore

@Suite struct PlacementTests {
    @Test func collisionsGetSuffixes() throws {
        let store = try Store.inMemory()
        let day = PlacementDay.day(ArchiveDay(year: 2027, month: 1, day: 15)!)
        try store.write { db in
            for id in ["1", "2", "3"] { try AssetRepository.upsert(db, makeAsset(id), timeZone: utc) }
            let stems = try ["1", "2", "3"].map {
                try AssetPlacementRepository.allocatePlacement(
                    db, assetKey: .local($0), baseStem: "2027-01-15 10.00.00_IMG", category: .camera, day: day, now: t0).nameStem
            }
            #expect(stems == ["2027-01-15 10.00.00_IMG", "2027-01-15 10.00.00_IMG (1)", "2027-01-15 10.00.00_IMG (2)"])
        }
    }

    /// Swift counts grapheme clusters, SQLite counts code points: flags, skin tones and combining
    /// marks must still find the names already taken, or the second insert breaks the cycle.
    @Test(arguments: ["undated_ảnh 🇻🇳", "IMG 👍🏽", "भारत", "ภาษาไทย", "e\u{301}te"])
    func collisionsAreFoundForMultiScalarCharacters(stem: String) throws {
        let store = try Store.inMemory()
        try store.write { db in
            for id in ["1", "2", "3"] { try AssetRepository.upsert(db, makeAsset(id), timeZone: utc) }
            let stems = try ["1", "2", "3"].map {
                try AssetPlacementRepository.allocatePlacement(
                    db, assetKey: .local($0), baseStem: stem, category: .camera, day: .unknown, now: t0).nameStem
            }
            #expect(Set(stems).count == 3)
            #expect(stems.dropFirst().allSatisfy { $0.hasSuffix(")") })
        }
    }

    @Test func caseInsensitiveCollisionAndPlacementFixedOnce() throws {
        let store = try Store.inMemory()
        try store.write { db in
            for id in ["1", "2"] { try AssetRepository.upsert(db, makeAsset(id), timeZone: utc) }
            let first = try AssetPlacementRepository.allocatePlacement(
                db, assetKey: .local("1"), baseStem: "IMG", category: .camera, day: .unknown, now: t0)
            let other = try AssetPlacementRepository.allocatePlacement(
                db, assetKey: .local("2"), baseStem: "img", category: .camera, day: .unknown, now: t0)
            #expect(other.nameStem == "img (1)")
            let again = try AssetPlacementRepository.allocatePlacement(
                db, assetKey: .local("1"), baseStem: "other", category: .saved, day: .unknown, now: t0)
            #expect(again == first)
            let row = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM name_alloc")
            #expect(row == 2)
        }
    }

    @Test func sameStemInDifferentCategoryDoesNotCollide() throws {
        let store = try Store.inMemory()
        try store.write { db in
            for id in ["1", "2"] { try AssetRepository.upsert(db, makeAsset(id), timeZone: utc) }
            _ = try AssetPlacementRepository.allocatePlacement(db, assetKey: .local("1"), baseStem: "x", category: .camera, day: .unknown, now: t0)
            let p = try AssetPlacementRepository.allocatePlacement(db, assetKey: .local("2"), baseStem: "x", category: .saved, day: .unknown, now: t0)
            #expect(p.nameStem == "x")
        }
    }

    @Test func missingAssetThrows() throws {
        let store = try Store.inMemory()
        #expect(throws: StoreError.self) {
            try store.write {
                try AssetPlacementRepository.allocatePlacement($0, assetKey: .local("none"), baseStem: "x", category: .camera, day: .unknown, now: t0)
            }
        }
    }

    @Test func concurrentAllocationsNeverCollide() async throws {
        let dir = try tempDirectory()
        let store = try Store.open(at: dir.appendingPathComponent("db.sqlite"))
        let count = 40
        try await store.write { db in
            for i in 0..<count { try AssetRepository.upsert(db, makeAsset("A\(i)"), timeZone: utc) }
        }
        let day = PlacementDay.day(ArchiveDay(year: 2027, month: 1, day: 15)!)
        let stems = try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<count {
                group.addTask {
                    try await store.write { db in
                        try AssetPlacementRepository.allocatePlacement(
                            db, assetKey: .local("A\(i)"), baseStem: "same", category: .camera, day: day, now: t0).nameStem
                    }
                }
            }
            var all: [String] = []
            for try await stem in group { all.append(stem) }
            return all
        }
        #expect(Set(stems).count == count)
        let expected = Set(["same"] + (1..<count).map { "same (\($0))" })
        #expect(Set(stems) == expected)
    }

    @Test func concurrentJobUpsertsConverge() async throws {
        let dir = try tempDirectory()
        let store = try Store.open(at: dir.appendingPathComponent("db.sqlite"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for gen in 1...20 {
                group.addTask {
                    try await store.write { db in
                        _ = try JobRepository.upsert(db, desired: desired(.googleDrive, .local("1"), gen: gen), now: t0)
                    }
                }
            }
            try await group.waitForAll()
        }
        let job = try await store.read { try JobRepository.fetch($0, identity: JobIdentity(destinationId: .googleDrive, assetKey: .local("1"), resType: .photo)) }
        #expect(job?.targetGen == 20)
        #expect(try await store.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM upload_job") } == 1)
    }
}

@Suite struct DayStatTests {
    @Test func recountComesFromTableNotAccumulation() throws {
        let store = try Store.inMemory()
        let day = ArchiveDay(date: t0, timeZone: utc)
        try store.write { db in
            try AssetRepository.upsert(db, makeAsset("1"), timeZone: utc)
            try AssetRepository.upsert(db, makeAsset("2"), timeZone: utc)
            try AssetRepository.upsert(db, makeAsset("3", category: .screenshot), timeZone: utc)
            #expect(try AssetPlacementRepository.recountDay(db, day: day).count == 2)
            #expect(try AssetPlacementRepository.recountDay(db, day: day).count == 2)
            try DayStatRepository.promote(db, day: day, now: t0)

            var gone = makeAsset("2")
            gone.deletedAt = t0
            try AssetRepository.upsert(db, gone, timeZone: utc)
            let stat = try AssetPlacementRepository.recountDay(db, day: day)
            #expect(stat.count == 1)
            #expect(stat.promoted, "recount keeps promotion")
        }
    }

    @Test func placedAssetCountsInPlacementDay() throws {
        let store = try Store.inMemory()
        let creation = ArchiveDay(date: t0, timeZone: utc)
        let other = ArchiveDay(year: 2020, month: 5, day: 5)!
        try store.write { db in
            try AssetRepository.upsert(db, makeAsset("1"), timeZone: utc)
            _ = try AssetPlacementRepository.allocatePlacement(db, assetKey: .local("1"), baseStem: "s", category: .camera, day: .day(other), now: t0)
            #expect(try AssetPlacementRepository.recountDay(db, day: creation).count == 0)
            #expect(try AssetPlacementRepository.recountDay(db, day: other).count == 1)
        }
    }

    @Test func promoteIsOneWay() throws {
        let store = try Store.inMemory()
        let day = ArchiveDay(date: t0, timeZone: utc)
        try store.write { db in
            try AssetPlacementRepository.recountDay(db, day: day)
            #expect(try DayStatRepository.promote(db, day: day, now: t0))
            #expect(try DayStatRepository.promote(db, day: day, now: t0) == false)
            try DayStatRepository.setPlace(db, day: day, state: .named, key: "VN|HCM", name: "Sài Gòn")
            let stat = try #require(try DayStatRepository.fetch(db, day: day))
            #expect(stat.placeState == .named && stat.placeName == "Sài Gòn" && stat.promotedAt == t0)
        }
    }
}
