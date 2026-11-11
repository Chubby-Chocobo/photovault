import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// The bookkeeping of cancelling an import: pending files are cancelled, the assets that have not reached a destination are
/// removed from the plan, and the job ends as cancelled. It runs in the engine's lane while no upload is in flight (as the
/// owner's command, at the start of a cycle round, or at launch) and does nothing for an import that already ended.
enum ImportCancellation {
    /// Finishes every cancel asked for and not yet done: in memory (`interrupts`) or stored before a relaunch. The cycle runs
    /// it at the start of a round, where no upload is in flight, because it takes pending jobs out of the plan.
    /// - Returns: how many imports it ended.
    static func settleRequested(env: EngineEnvironment, interrupts: ImportInterrupts, extensions: [any JobPlanningExtension]) async throws -> Int {
        let open = try await env.store.read { db in
            try SourceRepository.fetchAll(db).filter { $0.kind.isImport && $0.status.isOpen }
        }
        var settled = 0
        for source in open where interrupts.isCancelRequested(source.id) || source.config.cancelRequested == true {
            try await apply(source.id, env: env, extensions: extensions)
            interrupts.clearCancel(source.id)
            settled += 1
        }
        return settled
    }

    static func apply(_ id: SourceID, env: EngineEnvironment, extensions: [any JobPlanningExtension]) async throws {
        let settings = await env.settingsSnapshot()
        _ = try await env.store.write { db -> Bool in
            guard let source = try SourceRepository.fetch(db, id: id), source.status.isOpen else { return false }
            try ImportItemRepository.cancelPending(db, sourceId: id)
            let context = try env.context(db, settings)
            var dirty = Set<ArchiveDay>()
            let keys = try String.fetchAll(db, sql: """
                SELECT DISTINCT a.asset_key FROM asset a JOIN upload_job j ON j.asset_key = a.asset_key
                WHERE a.source_id = ? AND a.deleted_at IS NULL AND j.state IN ('pending', 'uploading', 'deferred')
                """, arguments: [id.rawValue])
            for raw in keys {
                guard let key = AssetKey(rawValue: raw), var asset = try AssetRepository.fetch(db, key: key) else { continue }
                asset.deletedAt = context.now
                try AssetRepository.upsert(db, asset, timeZone: context.timeZone)
                try EligibilityService.recompute(db, asset: asset, context: context, extensions: extensions)
                if asset.category == .camera, let creation = asset.creationDate { dirty.insert(ArchiveDay(date: creation, timeZone: context.timeZone)) }
            }
            try AssetFinalizer.recount(db, days: dirty, context: context)
            return try ImportCompletion.finish(db, id: id, as: .cancelled, now: context.now)
        }
    }
}
