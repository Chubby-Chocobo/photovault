import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Owner commands for one-time imports. They run in the exclusive lane, between cycle passes.
extension SyncCoordinator {
    /// Records the job of any import kind, then registers its adapter (database before side effect). The next cycle lists the folder.
    /// - Throws: `EngineError.notBaselined` until the first baseline is taken.
    @discardableResult
    public func startImport(source: any FolderImportSource, kind: SourceKind, displayName: String, config: SourceConfig) async throws -> SourceID {
        try await exclusive {
            // The owner cancelled while this waited for its turn: record nothing.
            try Task.checkCancellation()
            try await refuseLegacyLayout()
            guard baseline.isTaken else { throw EngineError.notBaselined }
            let record = SourceRecord(
                id: source.id, kind: kind, mode: .oneTime, displayName: displayName, config: config,
                status: .scanning, createdAt: env.clock.now)
            try await env.store.write { db in try SourceRepository.insert(db, record) }
            await env.sources.add(source)
        }
        await publish()
        return source.id
    }

    /// A Mac folder import; the app keeps its security-scoped bookmark with the job, and `locationPath` (home as `~`)
    /// for the owner to read in the history.
    @discardableResult
    public func startFolderImport(source: any FolderImportSource, displayName: String, bookmark: Data?, locationPath: String? = nil) async throws -> SourceID {
        try await startImport(
            source: source, kind: .localFolder, displayName: displayName,
            config: SourceConfig(bookmark: bookmark, locationPaths: locationPath.map { [$0] }))
    }

    /// Adopts the adapters of jobs that were open when the app last ran.
    public func registerSources(_ sources: [any FolderImportSource]) async {
        for source in sources { await env.sources.add(source) }
    }

    /// The owner signed in again: clears the hold and the "needs sign-in" mark of an import so it carries on
    /// in the next cycle instead of after the cooldown. A held job goes back to reading its files.
    public func resumeImportAfterSignIn(_ id: SourceID) async throws {
        try await exclusive {
            importHolds.clear(id)
            let now = env.clock.now
            try await env.store.write { db in
                guard let source = try SourceRepository.fetch(db, id: id), source.kind.isImport else { return }
                try EngineQueries.releaseExports(db, sourceId: id)
                if source.status == .offline {
                    try SourceRepository.setStatus(db, id: id, status: .scanning, reason: nil, now: now)
                } else if source.statusReason != nil {
                    try SourceRepository.setStatusReason(db, id: id, reason: nil)
                }
            }
        }
        await publish()
    }

    /// Cloud imports that are closed with no upload of their files left to run (nothing pending, uploading,
    /// deferred or missing at the destination, where a re-upload would read the source again), so their sign-in
    /// is no longer needed. Safe to ask at any time and to act on twice.
    ///
    /// Such an import also stops asking for a sign-in: a "sign in again" notice outlives the destination or the
    /// jobs that caused it, so it is cleared here whether or not a grant is stored.
    /// - Parameter grantExists: imports without a stored sign-in are not returned.
    public func closedImportsReadyToRelease(grantExists: @Sendable (SourceID) -> Bool = { _ in true }) async throws -> [SourceID] {
        let idle = try await env.store.write { db in
            let closed = try SourceRepository.fetchAll(db).filter { ($0.kind == .googleDrive || $0.kind == .dropbox) && !$0.status.isOpen }
            let idle = try closed.filter { source in
                try Bool.fetchOne(db, sql: """
                    SELECT NOT EXISTS(SELECT 1 FROM asset a JOIN upload_job j ON j.asset_key = a.asset_key
                                      WHERE a.source_id = ? AND a.deleted_at IS NULL
                                        AND j.state IN ('pending', 'uploading', 'deferred', 'missingRemote'))
                    """, arguments: [source.id.rawValue]) == true
            }
            for source in idle where source.statusReason == "signInRequired" {
                try SourceRepository.setStatusReason(db, id: source.id, reason: nil)
            }
            return idle.map(\.id)
        }
        return idle.filter(grantExists)
    }

    /// Drops the adapter of an import whose sign-in was let go. Exports that need it later find none and ask for a new sign-in.
    public func releaseImportSource(_ id: SourceID) async {
        await env.sources.remove(id)
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
