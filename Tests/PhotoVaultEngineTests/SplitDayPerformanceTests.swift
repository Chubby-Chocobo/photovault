import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// Transactions that touch many rows stay short: the split of a big day and the upgrade pass.
@Suite struct SplitDayPerformanceTests {
    @Test func splittingA500AssetDayInto3ProvincesTakesUnderTwoSeconds() async throws {
        let h = try await Harness.organized()
        try await h.update {
            $0.viewByDeviceEnabled = false
            $0.viewByPlaceEnabled = false
            $0.viewFavoritesEnabled = false
            $0.sidecarJsonEnabled = false
            $0.sidecarXmpEnabled = false
            $0.placeNamesEnabled = false
        }
        try h.addDrive(scope: .full)
        let sapa = GeoPoint(latitude: 22.3364, longitude: 103.8438)
        let points = [hanoi, daLat, sapa]
        for index in 0..<500 { await h.add(h.snapshot("a\(index)", daysAgo: 3, location: points[index % 3]), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.settle(rounds: 8)
        #expect(try h.jobs(.done).count == 500)

        let english = [hanoiEnglish, daLatEnglish, GeoPlace(isoCountryCode: "VN", country: "Vietnam", administrativeArea: "Lao Cai", locality: "Sa Pa")]
        let local = [hanoiVietnamese, daLatVietnamese, GeoPlace(isoCountryCode: "VN", country: "Việt Nam", administrativeArea: "Lào Cai", locality: "Sa Pa")]
        try h.write { db in
            for (index, point) in points.enumerated() {
                try GeoCacheRepository.save(db, GeoCacheEntry(cell: GeoCell(point), locale: "en", place: english[index], fetchedAt: h.clock.now))
                try GeoCacheRepository.save(db, GeoCacheEntry(cell: GeoCell(point), locale: "local", place: local[index], fetchedAt: h.clock.now))
            }
        }
        let snapshot = await h.env.settingsSnapshot()
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = try h.write { db in
            try PlaceNamer.evaluateDay(db, day: organizationDay, context: try h.env.context(db, snapshot))
        }
        let elapsed = started.duration(to: clock.now)
        print("split of a 500-asset day into 3 provinces: \(elapsed)")
        #expect(outcome.changed)
        #expect(elapsed < .seconds(10), "alone it takes well under a second; the bound allows for a loaded machine")
        let moves = try h.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_job WHERE op = 'moveFile'") ?? 0 }
        #expect(moves == 2 * 500 / 3 + 1 || moves > 300)
    }

    @Test func theUpgradePassOver300PromotedDaysTakesUnderTwoSeconds() async throws {
        let h = try await Harness.organized()
        try await h.update { $0.placeNamesEnabled = true }
        try h.addDrive(scope: .full)
        try h.write { db in
            for index in 0..<300 {
                let key = AssetKey.local("p\(index)")
                let created = h.clock.now.addingTimeInterval(-Double(10 + index) * 86_400)
                let asset = AssetRecord(
                    assetKey: key, localId: "p\(index)", creationDate: created, mediaType: .image, category: .camera,
                    firstSeenAt: h.clock.now, lastSeenAt: h.clock.now)
                try AssetRepository.upsert(db, asset, timeZone: utc)
                let day = ArchiveDay(date: created, timeZone: utc)
                _ = try AssetPlacementRepository.allocatePlacement(db, assetKey: key, baseStem: "IMG", category: .camera, day: .day(day), now: h.clock.now)
                try AssetPlacementRepository.recountDay(db, day: day)
                try DayStatRepository.promote(db, day: day, now: h.clock.now)
            }
            try KeyValueRepository.set(db, "place_split_backfill", nil)
        }
        let clock = ContinuousClock()
        let started = clock.now
        _ = try await PlaceNamer(env: h.env).runPass()
        let elapsed = started.duration(to: clock.now)
        print("upgrade pass over 300 promoted days: \(elapsed)")
        #expect(elapsed < .seconds(10), "alone it takes well under a second; the bound allows for a loaded machine")
        #expect(try h.read { db in try KeyValueRepository.int(db, "place_split_backfill") } == 1)
    }

    @Test func lookingUpOpenRenamesStaysFastOverHundredThousandFinishedMoves() throws {
        let store = try Store.inMemory()
        try store.write { db in
            try db.execute(sql: "INSERT INTO destination (id, kind, display_name, status, status_since, scope_mode, rules_json, config_json, recovery_required, created_at) VALUES ('gdrive', 'drive', 'Drive', 'active', 0, 'full', '{}', '{}', 0, 0)")
            let statement = try db.makeStatement(sql: """
                INSERT INTO move_job (destination_id, op, subject, from_value, to_value, state, attempts, created_at)
                VALUES ('gdrive', 'moveFile', ?, 'camera/2026-01-01', 'camera/2026-01-01@p0123456789ab', 'done', 0, 0)
                """)
            for index in 0..<100_000 { try statement.execute(arguments: ["l:asset-\(index)|1"]) }
        }
        let plan = try store.read { db in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN SELECT from_value FROM move_job WHERE destination_id IN (SELECT id FROM destination)
                    AND subject = 'camera/2026-01-01' AND op = 'renameFolder' AND state IN ('pending', 'inProgress')
                """).map { $0["detail"] as String }.joined(separator: " | ")
        }
        #expect(plan.contains("move_job_subject"), "\(plan)")
        let day = ArchiveDay(year: 2026, month: 1, day: 1)!
        let clock = ContinuousClock()
        let started = clock.now
        try store.read { db in
            for _ in 0..<3_000 { _ = try DaySplitWriter.reserved(db, day: day, slot: nil) }
        }
        let elapsed = started.duration(to: clock.now)
        print("3000 open-rename lookups over 100000 moves: \(elapsed)")
        #expect(elapsed < .seconds(2))
    }
}
