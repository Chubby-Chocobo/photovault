import Foundation
import Photos
import PhotoVaultCore

/// `PhotosSource` over PhotoKit. Holds no mutable state; every call reads the live library.
///
/// Scan cursor semantics: assets are fetched sorted by `creationDate` ascending (missing dates
/// first). A cursor is `"<offset>|<creationDate or ->|<localId>"` for the last asset returned. On
/// resume, if the asset at `offset` still has that local ID the scan continues at `offset + 1`;
/// otherwise (the library changed) the scan finds the last asset by ID, and failing that by binary
/// search on creation date. Assets inserted or removed while scanning are reconciled by the
/// persistent-change history, so a rare duplicate or skipped boundary asset is acceptable.
///
/// Loops over PhotoKit objects drain an autorelease pool per item: these calls run on the Swift concurrency
/// pool, whose threads drain their pool only when a job ends, so a loop over a whole page or library would
/// otherwise keep every `PHAsset` and resource it touched alive until it returns.
public final class PhotoKitSource: PhotosSource {
    static let mappingBatchSize = 500
    private let mapper: PhotoKitSnapshotMapper

    public init(utiResolver: any UTIResolver = UTTypeResolver()) {
        mapper = PhotoKitSnapshotMapper(utiResolver: utiResolver)
    }

    // MARK: Authorization

    public func authorizationStatus() -> PhotosAuthorization {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    public func requestAuthorization() async -> PhotosAuthorization {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    static func map(_ status: PHAuthorizationStatus) -> PhotosAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        case .limited: .limited
        @unknown default: .denied
        }
    }

    func requireAccess() throws {
        guard authorizationStatus().allowsReading else { throw PhotosSourceError.notAuthorized }
    }

    // MARK: Assets

    public func fetchAllAssets(after cursor: AssetCursor?, limit: Int) async throws -> AssetPage {
        try requireAccess()
        let options = Self.fetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: options)
        let start = Self.startIndex(in: result, cursor: cursor)
        let end = min(result.count, start + max(1, limit))
        var snapshots: [AssetSnapshot] = []
        var last: PHAsset?
        if start < end {
            for index in start..<end {
                autoreleasepool {
                    let asset = result.object(at: index)
                    snapshots.append(mapper.snapshot(of: asset))
                    last = asset
                }
            }
        }
        guard end < result.count, let last else { return AssetPage(assets: snapshots, nextCursor: nil) }
        return AssetPage(assets: snapshots, nextCursor: Self.cursor(offset: end - 1, asset: last))
    }

    public func assets(localIds: [String]) async throws -> [AssetSnapshot] {
        try requireAccess()
        guard !localIds.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: localIds, options: Self.fetchOptions())
        var snapshots: [AssetSnapshot] = []
        result.enumerateObjects { asset, _, _ in autoreleasepool { snapshots.append(self.mapper.snapshot(of: asset)) } }
        return snapshots
    }

    public func totalAssetCount() async throws -> Int {
        try requireAccess()
        return PHAsset.fetchAssets(with: Self.fetchOptions()).count
    }

    // MARK: Cursor

    static func cursor(offset: Int, asset: PHAsset) -> AssetCursor {
        let date = asset.creationDate.map { String($0.timeIntervalSinceReferenceDate) } ?? "-"
        return AssetCursor(value: "\(offset)|\(date)|\(asset.localIdentifier)")
    }

    static func startIndex(in result: PHFetchResult<PHAsset>, cursor: AssetCursor?) -> Int {
        guard let cursor else { return 0 }
        let parts = cursor.value.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let offset = Int(parts[0]) else { return 0 }
        let localId = String(parts[2])
        if offset < result.count, result.object(at: offset).localIdentifier == localId { return offset + 1 }
        for index in 0..<result.count where autoreleasepool(invoking: { result.object(at: index).localIdentifier == localId }) {
            return index + 1
        }
        // Last asset is gone: first asset strictly after its creation date.
        let pivot = TimeInterval(parts[1]) ?? -.greatestFiniteMagnitude
        var low = 0, high = result.count
        while low < high {
            let mid = (low + high) / 2
            let date = autoreleasepool { result.object(at: mid).creationDate?.timeIntervalSinceReferenceDate } ?? -.greatestFiniteMagnitude
            if date <= pivot { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: Identifier mappings

    public func cloudIdentifierMappings(localIds: [String]) async throws -> [String: String] {
        try requireAccess()
        var mapped: [String: String] = [:]
        for batch in Self.batches(localIds, size: Self.mappingBatchSize) {
            autoreleasepool {
                let results = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: batch)
                for (localId, result) in results {
                    guard case .success(let cloudId) = result else { continue }
                    mapped[localId] = cloudId.stringValue
                }
            }
        }
        return mapped
    }

    public func localIdentifierMappings(cloudIds: [String]) async throws -> [String: String] {
        try requireAccess()
        var mapped: [String: String] = [:]
        for batch in Self.batches(cloudIds, size: Self.mappingBatchSize) {
            autoreleasepool {
                let results = PHPhotoLibrary.shared().localIdentifierMappings(for: batch.map { PHCloudIdentifier(stringValue: $0) })
                for (cloudId, result) in results {
                    guard case .success(let localId) = result else { continue }
                    mapped[cloudId.stringValue] = localId
                }
            }
        }
        return mapped
    }

    static func batches<T>(_ items: [T], size: Int) -> [[T]] {
        stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    // MARK: Albums

    public func albums() async throws -> [AlbumSnapshot] {
        try requireAccess()
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var albums: [AlbumSnapshot] = []
        collections.enumerateObjects { collection, _, _ in
            autoreleasepool {
                var members: [String] = []
                PHAsset.fetchAssets(in: collection, options: Self.fetchOptions())
                    .enumerateObjects { asset, _, _ in autoreleasepool { members.append(asset.localIdentifier) } }
                albums.append(AlbumSnapshot(localId: collection.localIdentifier, title: collection.localizedTitle ?? "", assetLocalIds: members))
            }
        }
        return albums
    }
}
