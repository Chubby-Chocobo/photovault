import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// Places category-final assets and creates their jobs after a scan or an interrupted pass.
/// Idempotent: placement is fixed once and job upserts change nothing the second time.
struct FinalizePass: Sendable {
    let env: EngineEnvironment
    var extensions: [any JobPlanningExtension] = []

    private static let finalizedKey = "scan_finalized"

    var isScanFinalized: Bool {
        ((try? env.store.read { db in try KeyValueRepository.int(db, Self.finalizedKey) }) ?? nil) == 1
    }

    /// Finalizes every live asset once after the scan completed; later passes only place leftovers.
    func runAfterScan() async throws {
        if isScanFinalized {
            try await placeLeftovers()
            return
        }
        var cursor = ""
        let env = env
        let extensions = extensions
        while true {
            try Task.checkCancellation()
            let snapshot = await env.settingsSnapshot()
            let start = cursor
            let last: String? = try await env.store.write { db in
                let keys = try EngineQueries.liveAssetKeys(db, after: start, limit: 500)
                guard !keys.isEmpty else { return nil }
                let context = try env.context(db, snapshot)
                var dirty = Set<ArchiveDay>()
                for key in keys { try AssetFinalizer.finalize(db, key: key, context: context, dirtyDays: &dirty, extensions: extensions) }
                try AssetFinalizer.recount(db, days: dirty, settings: context.settings)
                return keys.last?.rawValue
            }
            guard let last else { break }
            cursor = last
        }
        try await env.store.write { db in try KeyValueRepository.set(db, Self.finalizedKey, 1) }
    }

    /// Places assets whose category is final but that have no placement yet.
    @discardableResult
    func placeLeftovers() async throws -> Int {
        var total = 0
        let env = env
        let extensions = extensions
        while true {
            let snapshot = await env.settingsSnapshot()
            let count: Int = try await env.store.write { db in
                let keys = try EngineQueries.unplacedFinalAssetKeys(db, limit: 500)
                guard !keys.isEmpty else { return 0 }
                let context = try env.context(db, snapshot)
                var dirty = Set<ArchiveDay>()
                for key in keys { try AssetFinalizer.finalize(db, key: key, context: context, dirtyDays: &dirty, extensions: extensions) }
                try AssetFinalizer.recount(db, days: dirty, settings: context.settings)
                return keys.count
            }
            if count == 0 { return total }
            total += count
        }
    }
}
