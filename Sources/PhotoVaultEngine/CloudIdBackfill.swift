import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// FR-53: learns the cloud identifier of assets keyed by their local id, in batches of at most 500.
/// The key never changes; the identifier becomes `cloud_id` and an alias, so a library rebuild
/// can re-attach the asset (spec 8.1). Reconciliation and recovery run a full pass first.
struct CloudIdBackfill: Sendable {
    static let batchSize = 500
    private static let nextPassKey = "cloudid_backfill:next_pass_at"
    /// Assets that cannot be mapped (no iCloud) are asked again only this often by the cycle.
    private static let unresolvedRetry: TimeInterval = 3600

    let env: EngineEnvironment

    private struct Pending: Sendable {
        var key: String
        var localId: String
    }

    /// One pass over every asset without a cloud identifier. A mapping error aborts the pass and is
    /// rethrown: callers that need the pass complete (reconciliation, recovery) must not go on.
    /// - Parameter force: ignore the retry pause of unresolvable assets.
    /// - Returns: the number of identifiers recorded.
    @discardableResult
    func runAll(force: Bool) async throws -> Int {
        let now = env.clock.now
        if !force, let next = try await env.store.read({ db in try KeyValueRepository.date(db, Self.nextPassKey) }), next > now { return 0 }
        var cursor = ""
        var recorded = 0
        var seen = 0
        while true {
            try Task.checkCancellation()
            let start = cursor
            let batch: [Pending] = try await env.store.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT asset_key, local_id FROM asset
                    WHERE cloud_id IS NULL AND deleted_at IS NULL AND asset_key > ? ORDER BY asset_key LIMIT ?
                    """, arguments: [start, Self.batchSize]).map { Pending(key: $0["asset_key"], localId: $0["local_id"]) }
            }
            guard let last = batch.last else { break }
            cursor = last.key
            seen += batch.count
            let mapping = try await env.photos.cloudIdentifierMappings(localIds: batch.map(\.localId))
            guard !mapping.isEmpty else { continue }
            recorded += try await env.store.write { db in try Self.record(db, batch: batch, mapping: mapping) }
        }
        let next: Date? = recorded == 0 && seen > 0 ? env.clock.now.addingTimeInterval(Self.unresolvedRetry) : nil
        try await env.store.write { db in try KeyValueRepository.set(db, Self.nextPassKey, next) }
        if recorded > 0 { env.log.log(.info, category: "cloudid", "recorded \(recorded) cloud identifiers") }
        return recorded
    }

    private static func record(_ db: Database, batch: [Pending], mapping: [String: String]) throws -> Int {
        var count = 0
        for item in batch {
            guard let cloud = mapping[item.localId], !cloud.isEmpty, let key = AssetKey(rawValue: item.key) else { continue }
            // Two assets never share a cloud identifier; the second stays as it is.
            let taken = try Int.fetchOne(db, sql: "SELECT 1 FROM asset WHERE cloud_id = ? AND asset_key != ? LIMIT 1", arguments: [cloud, item.key])
            guard taken == nil else { continue }
            try db.execute(sql: "UPDATE asset SET cloud_id = ? WHERE asset_key = ? AND cloud_id IS NULL", arguments: [cloud, item.key])
            guard db.changesCount > 0 else { continue }
            try AssetRepository.addAlias(db, alias: cloud, to: key)
            // Sidecars carry the cloud identifier (FR-90): they are refreshed.
            try DirtyQueue.mark(db, [.sidecar], id: item.key)
            count += 1
        }
        return count
    }
}

/// Step 10 of the cycle.
struct CloudIdBackfillStage: CycleStage {
    let backfill: CloudIdBackfill
    var step: CycleStep { .cloudIds }

    func run(trigger: SyncTrigger) async throws -> Bool {
        do {
            return try await backfill.runAll(force: false) > 0
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Photos can refuse while the library is busy; the next cycle asks again.
            backfill.env.log.log(.notice, category: "cloudid", "backfill pass failed type=\(type(of: error))")
            return false
        }
    }
}
