import Foundation
import GRDB
import PhotoVaultStore
import Testing
@testable import PhotoVaultEngine

@Suite struct CloudIdQueryPlanTests {
    @Test func theBackfillBatchWalksTheCloudIdIndexNotTheSourceIndex() async throws {
        let store = try Store.inMemory()
        try await store.read { db in
            let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + CloudIdBackfill.pendingBatchSQL, arguments: ["", 500])
                .map { $0["detail"] as String }.joined(separator: " | ")
            #expect(!plan.contains("asset_source"), "\(plan)")
            #expect(plan.contains("asset_cloud_id") || plan.contains("sqlite_autoindex_asset") || plan.contains("PRIMARY KEY"), "\(plan)")
        }
    }
}
