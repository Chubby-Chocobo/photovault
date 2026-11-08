import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

public enum ReconciliationReason: String, Sendable, Equatable {
    case tokenExpired, changeDetailsUnavailable, requested
}

/// Hook for the reconciliation implementation (FR-13): runs when the change history cannot be
/// replayed. It owns the FR-53 backfill, the full listing and the new token.
public protocol ReconciliationRunning: Sendable {
    func reconcile(reason: ReconciliationReason) async throws
}

public enum ChangeProcessingResult: Sendable, Equatable {
    case upToDate(processed: Int)
    /// The scan is not `complete`, so incremental processing must wait (FR-10).
    case scanIncomplete
    case needsReconciliation(ReconciliationReason)
}

/// FR-12: replays `PHPersistentChange`s. Photos reads (snapshots, cloud ids, albums) happen
/// before the transaction; each change then commits in one DB-only transaction together with its
/// own token, so a crash replays at most that change.
public actor ChangeTracker {
    private let env: EngineEnvironment
    private let extensions: [any JobPlanningExtension]

    init(env: EngineEnvironment, extensions: [any JobPlanningExtension] = []) {
        self.env = env
        self.extensions = extensions
    }

    @discardableResult
    public func process() async throws -> ChangeProcessingResult {
        let (scan, tokenData) = try await env.store.read { db in
            (try KeyValueRepository.scanState(db), try KeyValueRepository.data(db, KeyValueRepository.Key.changeToken))
        }
        guard scan == .complete else { return .scanIncomplete }
        guard let tokenData else { throw EngineError.notBaselined }
        let changes: [PersistentChange]
        do {
            changes = try await env.photos.fetchPersistentChanges(since: ChangeToken(data: tokenData))
        } catch PhotosSourceError.tokenExpired {
            return .needsReconciliation(.tokenExpired)
        } catch PhotosSourceError.changeDetailsUnavailable {
            return .needsReconciliation(.changeDetailsUnavailable)
        }
        for change in changes {
            try Task.checkCancellation()
            try await apply(change)
        }
        return .upToDate(processed: changes.count)
    }

    private func apply(_ change: PersistentChange) async throws {
        // Prefetch everything that needs PhotoKit before the transaction opens.
        let wanted = Array(Set(change.insertedLocalIds + change.updatedLocalIds))
        var fetched: [String: AssetSnapshot] = [:]
        if !wanted.isEmpty {
            for snapshot in try await env.photos.assets(localIds: wanted) { fetched[snapshot.localId] = snapshot }
            let missingCloud = fetched.values.filter { $0.cloudId == nil }.map(\.localId)
            if !missingCloud.isEmpty {
                let mapping = try await env.photos.cloudIdentifierMappings(localIds: Array(missingCloud.prefix(500)))
                for (local, cloud) in mapping { fetched[local]?.cloudId = cloud }
            }
        }
        let snapshots = fetched
        let albums = change.albumsChanged ? try await env.photos.albums() : nil
        let settings = await env.settingsSnapshot()
        let env = env
        let extensions = extensions
        let inserted = Set(change.insertedLocalIds)
        try await env.store.write { db in
            let context = try env.context(db, settings)
            var touched: [AssetKey] = []
            var dirty = Set<ArchiveDay>()
            for localId in wanted {
                guard let snapshot = snapshots[localId] else { continue }
                let membership = try Self.albumTitles(db, localId: localId, key: nil)
                let result = try AssetRecordFactory.ingest(
                    db, snapshot, albums: membership, insertedAt: context.now,
                    stampInsertedOnExisting: inserted.contains(localId), context: context)
                touched.append(result.record.assetKey)
            }
            for localId in change.deletedLocalIds {
                guard var asset = try AssetRepository.find(db, localId: localId, cloudId: nil) else { continue }
                // Deletions only mark the row; the backup is never touched (T23).
                asset.deletedAt = context.now
                try AssetRepository.upsert(db, asset, timeZone: context.timeZone)
                if asset.category == .camera, let creation = asset.creationDate {
                    dirty.insert(ArchiveDay(date: creation, timeZone: context.timeZone))
                }
            }
            if let albums { touched.append(contentsOf: try Self.refreshAlbums(db, albums: albums)) }
            for key in Set(touched) {
                try AssetFinalizer.finalize(db, key: key, context: context, dirtyDays: &dirty, extensions: extensions)
            }
            try AssetFinalizer.recount(db, days: dirty, settings: context.settings)
            try KeyValueRepository.set(db, KeyValueRepository.Key.changeToken, change.token.data)
        }
    }

    /// Titles of the albums an already stored asset belongs to (new assets have none yet).
    private static func albumTitles(_ db: Database, localId: String, key: AssetKey?) throws -> [AlbumMember.Membership] {
        guard let asset = try AssetRepository.find(db, localId: localId, cloudId: nil) else { return [] }
        return try AssetRepository.albums(db, for: asset.assetKey).map { .init(id: $0.albumLocalId, title: $0.albumTitle) }
    }

    /// Rebuilds `album_member` from the album list; returns the assets whose membership changed.
    private static func refreshAlbums(_ db: Database, albums: [AlbumSnapshot]) throws -> [AssetKey] {
        let index = try EngineQueries.localIdIndex(db)
        var desired: [AssetKey: [AlbumMember.Membership]] = [:]
        for album in albums {
            for localId in album.assetLocalIds {
                guard let key = index[localId] else { continue }
                desired[key, default: []].append(.init(id: album.localId, title: album.title))
            }
        }
        var changed: [AssetKey] = []
        let previous = try EngineQueries.assetKeysWithAlbums(db)
        for key in Set(desired.keys).union(previous) {
            let members = (desired[key] ?? []).sorted { $0.id < $1.id }
            let current = try AssetRepository.albums(db, for: key).map { AlbumMember.Membership(id: $0.albumLocalId, title: $0.albumTitle) }
            guard members != current else { continue }
            try AssetRepository.setAlbums(
                db, for: key, members: members.map { AlbumMember(albumLocalId: $0.id, albumTitle: $0.title, assetKey: key) })
            changed.append(key)
        }
        return changed
    }
}
