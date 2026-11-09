import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

@Suite struct ClassifyPassWalkTests {
    private func addProvisional(_ h: Harness, count: Int, prefix: String) async {
        for i in 0..<count { await h.fakePhotos.add(h.snapshot("\(prefix)\(i)", daysAgo: Double(i % 300 + 1)), recordChange: false) }
    }

    @Test func assetsThatCanNeverQualifyAreNotWalked() async throws {
        let h = try await Harness { $0.classifyBatchSize = 25 }
        try h.addDrive(scope: .newOnly)
        await addProvisional(h, count: 300, prefix: "old")
        try await h.baseline(.googleDrive)
        _ = try await h.coordinator.scanner.run()
        let first = try await h.coordinator.classifier.runPass()
        let second = try await h.coordinator.classifier.runPass()
        #expect(first.walked == 0)
        #expect(second.walked == 0)
        #expect(first.classified == 0)
    }

    @Test func eachProvisionalAssetIsWalkedOncePerPass() async throws {
        let h = try await Harness { $0.classifyBatchSize = 25 }
        try h.addDrive(scope: .full)
        await addProvisional(h, count: 200, prefix: "a")
        try await h.baseline(.googleDrive)
        _ = try await h.coordinator.scanner.run()
        let result = try await h.coordinator.classifier.runPass()
        #expect(result.walked == 200)
        #expect(result.classified == 200)
    }

    @Test func passStopsAtTheFirstRateLimitedRefusal() async throws {
        let h = try await Harness { $0.classifyBatchSize = 25 }
        try h.addDrive(scope: .full)
        await addProvisional(h, count: 200, prefix: "a")
        try await h.baseline(.googleDrive)
        _ = try await h.coordinator.scanner.run()
        h.system.set(SystemSnapshot(onACPower: false))
        let result = try await h.coordinator.classifier.runPass()
        #expect(result.classified == 0)
        #expect(result.walked == 1)
    }

    @Test func pagingVisitsEveryRowOnceInClassifyOrderAndUsesTheIndex() async throws {
        let store = try Store.inMemory()
        let count = 1_000
        try await store.write { db in
            for i in 0..<count {
                var asset = AssetRecord(
                    assetKey: .local("k\(i)"), localId: "k\(i)", creationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(i % 50) * 86_400),
                    mediaType: .image, category: .saved, firstSeenAt: Date(), lastSeenAt: Date())
                asset.categoryProvisional = true
                asset.insertedAt = i % 10 == 0 ? Date(timeIntervalSince1970: 1_800_000_000) : nil
                try AssetRepository.upsert(db, asset, timeZone: TimeZone(identifier: "UTC")!)
            }
        }
        let scope = ClassifyScope(destinations: [DestinationRecord(id: .googleDrive, displayName: "Drive", statusSince: Date(), createdAt: Date())])
        var cursor: EngineQueries.ProvisionalCursor?
        var seen: [String] = []
        var pages = 0
        while true {
            let start = cursor
            let page = try await store.read { db in try EngineQueries.provisionalPage(db, after: start, limit: 25, scope: scope) }
            guard let last = page.last else { break }
            pages += 1
            seen += page.map(\.key.rawValue)
            cursor = last.cursor
        }
        #expect(seen.count == count)
        #expect(Set(seen).count == count)
        #expect(pages == count / 25)
        let insertedFirst = seen.prefix(100).allSatisfy { key in (Int(key.drop { !$0.isNumber }) ?? 1) % 10 == 0 }
        #expect(insertedFirst)
        let plan = try await store.read { db in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN SELECT asset_key FROM asset
                WHERE category_provisional = 1 AND deleted_at IS NULL AND (inserted_at IS NULL) = 1
                  AND (COALESCE(creation_date, '') < '2024' OR (COALESCE(creation_date, '') = '2024' AND asset_key < 'k5'))
                ORDER BY COALESCE(creation_date, '') DESC, asset_key DESC LIMIT 25
                """).map { ($0["detail"] as String) }.joined(separator: " | ")
        }
        #expect(plan.contains("asset_provisional_order"))
        #expect(!plan.contains("TEMP B-TREE"))
    }
}
