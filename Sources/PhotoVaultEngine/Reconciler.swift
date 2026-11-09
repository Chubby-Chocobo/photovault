import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// FR-13: rebuilds the library state when the change history cannot be replayed (token expired) or
/// the owner asks. FR-53 first; then one pass over every asset of the library; a new token last,
/// taken before the pass so anything that changes meanwhile is replayed afterwards.
///
/// - Assets not in the database (after alias / cloud id re-attach) are new: `inserted_at = now`.
///   An asset the scan recorded earlier is never new, whatever changed (a photo unhidden after the
///   baseline keeps `inserted_at = NULL`, T4b).
/// - Assets gone from the library only get `deleted_at`; the backup is never touched (T23).
/// - A changed `modificationDate` queues the edit gate and a sidecar refresh.
actor Reconciler: ReconciliationRunning {
    private let env: EngineEnvironment
    private let backfill: CloudIdBackfill
    private let extensions: [any JobPlanningExtension]
    private let afterReconcile: @Sendable () async throws -> Void
    private var running = false

    init(env: EngineEnvironment, backfill: CloudIdBackfill, extensions: [any JobPlanningExtension],
         afterReconcile: @escaping @Sendable () async throws -> Void) {
        self.env = env
        self.backfill = backfill
        self.extensions = extensions
        self.afterReconcile = afterReconcile
    }

    func reconcile(reason: ReconciliationReason) async throws {
        guard !running else { return }
        running = true
        defer { running = false }
        guard try await env.store.read({ db in try KeyValueRepository.scanState(db) }) == .complete else {
            throw EngineError.invalidState("reconciliation needs a complete scan")
        }
        try await backfill.runAll(force: true)
        let token = try await env.photos.currentChangeToken()
        var albumIndex: [String: [AlbumMember.Membership]] = [:]
        for album in try await env.photos.albums() {
            for id in album.assetLocalIds { albumIndex[id, default: []].append(.init(id: album.localId, title: album.title)) }
        }
        var seen = Set<AssetKey>()
        var cursor: AssetCursor?
        var created = 0
        repeat {
            try Task.checkCancellation()
            let page = try await env.photos.fetchAllAssets(after: cursor, limit: env.tuning.scanBatchSize)
            let snapshots = try await withCloudIds(page.assets)
            let result = try await apply(snapshots, albums: albumIndex)
            seen.formUnion(result.keys)
            created += result.created
            cursor = page.nextCursor
        } while cursor != nil
        let deleted = try await markGone(seen: seen)
        try await env.store.write { db in try KeyValueRepository.set(db, KeyValueRepository.Key.changeToken, token.data) }
        try await afterReconcile()
        env.log.log(.info, category: "reconcile", "reason=\(reason.rawValue) new=\(created) gone=\(deleted)")
    }

    /// Cloud identifiers for assets the database does not know by local id, so a rebuilt library
    /// re-attaches instead of looking new.
    private func withCloudIds(_ assets: [AssetSnapshot]) async throws -> [AssetSnapshot] {
        let unknown: [String] = try await env.store.read { db in
            try assets.filter { $0.cloudId == nil }.filter { try AssetRepository.find(db, localId: $0.localId, cloudId: nil) == nil }.map(\.localId)
        }
        guard !unknown.isEmpty else { return assets }
        var mapping: [String: String] = [:]
        for batch in stride(from: 0, to: unknown.count, by: CloudIdBackfill.batchSize) {
            let ids = Array(unknown[batch..<min(batch + CloudIdBackfill.batchSize, unknown.count)])
            mapping.merge(try await env.photos.cloudIdentifierMappings(localIds: ids)) { _, new in new }
        }
        return assets.map { snapshot in
            var copy = snapshot
            if copy.cloudId == nil { copy.cloudId = mapping[snapshot.localId] }
            return copy
        }
    }

    private func apply(_ snapshots: [AssetSnapshot], albums: [String: [AlbumMember.Membership]]) async throws -> (keys: Set<AssetKey>, created: Int) {
        let settings = await env.settingsSnapshot()
        let env = env
        let extensions = extensions
        return try await env.store.write { db in
            let context = try env.context(db, settings)
            var keys = Set<AssetKey>()
            var created = 0
            var dirty = Set<ArchiveDay>()
            for snapshot in snapshots {
                let before = try AssetRepository.find(db, localId: snapshot.localId, cloudId: snapshot.cloudId)
                let beforeAlbums = try before.map { try AssetRepository.albums(db, for: $0.assetKey).map(\.albumLocalId) } ?? []
                let members = albums[snapshot.localId] ?? []
                let result = try AssetRecordFactory.ingest(
                    db, snapshot, albums: members, insertedAt: context.now, stampInsertedOnExisting: false, context: context)
                let key = result.record.assetKey
                keys.insert(key)
                var changed = before == nil
                if let before {
                    var comparable = result.record
                    comparable.lastSeenAt = before.lastSeenAt
                    changed = comparable != before || beforeAlbums.sorted() != members.map(\.id).sorted()
                    if before.modificationDate != result.record.modificationDate { try DirtyQueue.mark(db, asset: key) }
                } else {
                    created += 1
                }
                if changed { try AssetFinalizer.finalize(db, key: key, context: context, dirtyDays: &dirty, extensions: extensions) }
            }
            try AssetFinalizer.recount(db, days: dirty, context: context)
            return (keys, created)
        }
    }

    /// Live assets the library no longer lists get `deleted_at`.
    private func markGone(seen: Set<AssetKey>) async throws -> Int {
        let live: [AssetKey] = try await env.store.read { db in
            try String.fetchAll(db, sql: "SELECT asset_key FROM asset WHERE deleted_at IS NULL AND source_id = 'photos'").compactMap(AssetKey.init(rawValue:))
        }
        let gone = live.filter { !seen.contains($0) }
        let settings = await env.settingsSnapshot()
        let env = env
        let extensions = extensions
        for batch in stride(from: 0, to: gone.count, by: 500) {
            let keys = Array(gone[batch..<min(batch + 500, gone.count)])
            try await env.store.write { db in
                let context = try env.context(db, settings)
                var dirty = Set<ArchiveDay>()
                for key in keys {
                    guard var asset = try AssetRepository.fetch(db, key: key) else { continue }
                    asset.deletedAt = context.now
                    try AssetRepository.upsert(db, asset, timeZone: context.timeZone)
                    try EligibilityService.recompute(db, asset: asset, context: context, extensions: extensions)
                    if asset.category == .camera, let creation = asset.creationDate {
                        dirty.insert(ArchiveDay(date: creation, timeZone: context.timeZone))
                    }
                }
                try AssetFinalizer.recount(db, days: dirty, context: context)
            }
        }
        return gone.count
    }
}
