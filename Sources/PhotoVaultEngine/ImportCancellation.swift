import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// The bookkeeping of cancelling an import: pending files are cancelled, the assets that have not reached a destination are
/// removed from the plan, and the job ends as cancelled. It runs in the engine's lane (as the owner's command or from the
/// cycle's import stage) and does nothing for an import that already ended.
enum ImportCancellation {
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
