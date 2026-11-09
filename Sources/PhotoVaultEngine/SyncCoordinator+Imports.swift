import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Owner commands for one-time imports. They run in the exclusive lane, between cycle passes.
extension SyncCoordinator {
    /// Records the job, then registers its adapter (database before side effect). The next cycle lists the folder.
    /// - Throws: `EngineError.notBaselined` until the first baseline is taken.
    @discardableResult
    public func startFolderImport(source: any FolderImportSource, displayName: String, bookmark: Data?) async throws -> SourceID {
        try await exclusive {
            try await refuseLegacyLayout()
            guard baseline.isTaken else { throw EngineError.notBaselined }
            let record = SourceRecord(
                id: source.id, kind: .localFolder, mode: .oneTime, displayName: displayName, config: SourceConfig(bookmark: bookmark),
                status: .scanning, createdAt: env.clock.now)
            try await env.store.write { db in try SourceRepository.insert(db, record) }
            await env.sources.add(source)
        }
        await publish()
        return source.id
    }

    /// Adopts the adapters of jobs that were open when the app last ran.
    public func registerSources(_ sources: [any FolderImportSource]) async {
        for source in sources { await env.sources.add(source) }
    }

    /// Stops ingesting and treats files not yet uploaded as removed: their pending jobs are cancelled
    /// and what already reached a destination stays. Running the same import again brings them back.
    public func cancelImport(_ id: SourceID) async throws {
        try await exclusive {
            let env = env
            let settings = await env.settingsSnapshot()
            let extensions = planningExtensions
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
            // The adapter stays: the assets kept by a cancel can still go to a destination added later.
        }
        await publish()
    }
}
