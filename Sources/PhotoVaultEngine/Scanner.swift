import Foundation
import PhotoVaultCore
import PhotoVaultStore

public struct ScanProgress: Sendable, Equatable {
    public var state: ScanState
    /// Assets written by this call.
    public var scanned: Int
}

/// FR-10: records every asset (hidden and burst frames included) without exporting anything.
/// Resumable through `scan_state` and the cursor; each batch is one transaction that also moves
/// the cursor, so a crash repeats at most one batch, and re-ingesting a batch is idempotent.
/// Runs on its own actor, never on the main actor (NFR-08).
public actor Scanner {
    private let env: EngineEnvironment
    private var albumIndex: [String: [AlbumMember.Membership]]?

    init(env: EngineEnvironment) { self.env = env }

    public func state() throws -> ScanState { try env.store.read { db in try KeyValueRepository.scanState(db) } }

    /// Scans one page. Returns `.complete` when there is nothing (more) to do.
    @discardableResult
    public func runBatch() async throws -> ScanProgress {
        let (current, cursorText) = try await env.store.read { db in
            (try KeyValueRepository.scanState(db), try KeyValueRepository.string(db, KeyValueRepository.Key.scanCursor))
        }
        if current == .complete { return ScanProgress(state: .complete, scanned: 0) }
        let albums = try await loadAlbums()
        let page = try await env.photos.fetchAllAssets(after: cursorText.map(AssetCursor.init(value:)), limit: env.tuning.scanBatchSize)
        let snapshot = await env.settingsSnapshot()
        let env = env
        let next = page.nextCursor?.value
        try await env.store.write { db in
            let context = try env.context(db, snapshot)
            for asset in page.assets {
                try AssetRecordFactory.ingest(
                    db, asset, albums: albums[asset.localId] ?? [], insertedAt: nil, stampInsertedOnExisting: false, context: context)
            }
            try KeyValueRepository.set(db, KeyValueRepository.Key.scanCursor, next)
            try KeyValueRepository.setScanState(db, next == nil ? .complete : .running)
        }
        return ScanProgress(state: next == nil ? .complete : .running, scanned: page.assets.count)
    }

    /// Scans to the end (or until `maxBatches`).
    @discardableResult
    public func run(maxBatches: Int = .max) async throws -> ScanProgress {
        var total = 0
        var last = ScanProgress(state: try state(), scanned: 0)
        var batches = 0
        while last.state != .complete, batches < maxBatches {
            try Task.checkCancellation()
            last = try await runBatch()
            total += last.scanned
            batches += 1
        }
        return ScanProgress(state: last.state, scanned: total)
    }

    private func loadAlbums() async throws -> [String: [AlbumMember.Membership]] {
        if let albumIndex { return albumIndex }
        var index: [String: [AlbumMember.Membership]] = [:]
        for album in try await env.photos.albums() {
            for id in album.assetLocalIds { index[id, default: []].append(.init(id: album.localId, title: album.title)) }
        }
        albumIndex = index
        return index
    }
}
