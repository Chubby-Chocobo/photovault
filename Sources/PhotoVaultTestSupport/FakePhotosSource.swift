import CryptoKit
import Foundation
import PhotoVaultCore

/// In-memory Photos library. Tokens are change counters; history can be truncated to simulate
/// expired tokens.
public actor FakePhotosSource: PhotosSource {
    public struct Failure: Error, Hashable {}

    private var order: [String] = []
    private var snapshots: [String: AssetSnapshot] = [:]
    private var data: [String: [ResourceType: Data]] = [:]
    private var headerMetadata: [String: CaptureMetadata] = [:]
    private var adjustmentHashes: [String: String] = [:]
    private var albumList: [AlbumSnapshot] = []
    private var changes: [PersistentChange] = []
    private var counter = 0
    private var oldestAvailable = 0
    private var authorization: PhotosAuthorization = .authorized
    private var failingExports: [String: Int] = [:]
    public private(set) var exportCount: [String: Int] = [:]
    public private(set) var headerReads: [String] = []

    public init() {}

    // MARK: Library mutation (test API)

    /// Adds an asset and records an "inserted" change.
    public func add(_ snapshot: AssetSnapshot, resources resourceData: [ResourceType: Data] = [:],
                    header: CaptureMetadata? = nil, recordChange: Bool = true) {
        if snapshots[snapshot.localId] == nil { order.append(snapshot.localId) }
        snapshots[snapshot.localId] = snapshot
        var payload = resourceData
        for r in snapshot.resources where payload[r.type] == nil {
            payload[r.type] = Data("\(snapshot.localId)/\(r.type.rawValue)".utf8)
        }
        data[snapshot.localId] = payload
        if let header { headerMetadata[snapshot.localId] = header }
        if recordChange { record(PersistentChange(token: nextToken(), insertedLocalIds: [snapshot.localId])) }
    }

    public func update(_ snapshot: AssetSnapshot, resources resourceData: [ResourceType: Data]? = nil) {
        snapshots[snapshot.localId] = snapshot
        if let resourceData { data[snapshot.localId, default: [:]].merge(resourceData) { _, new in new } }
        record(PersistentChange(token: nextToken(), updatedLocalIds: [snapshot.localId]))
    }

    public func delete(localId: String) {
        snapshots[localId] = nil
        order.removeAll { $0 == localId }
        record(PersistentChange(token: nextToken(), deletedLocalIds: [localId]))
    }

    public func setAlbums(_ albums: [AlbumSnapshot]) {
        albumList = albums
        record(PersistentChange(token: nextToken(), albumsChanged: true))
    }

    public func setAdjustmentHash(_ hash: String?, for localId: String) { adjustmentHashes[localId] = hash }
    public func setAuthorization(_ value: PhotosAuthorization) { authorization = value }
    /// Next `times` exports of `localId` fail with a network error.
    public func failExports(of localId: String, times: Int) { failingExports[localId] = times }
    /// Drops change history so tokens older than now expire.
    public func expireHistory() { oldestAvailable = counter }

    /// Replaces local identifiers as a library rebuild would; cloud IDs stay.
    public func rebuildLibrary(renaming map: [String: String]) {
        var newOrder: [String] = []
        for old in order {
            let new = map[old] ?? old
            if var s = snapshots.removeValue(forKey: old) {
                s.localId = new
                snapshots[new] = s
            }
            if let d = data.removeValue(forKey: old) { data[new] = d }
            if let h = headerMetadata.removeValue(forKey: old) { headerMetadata[new] = h }
            newOrder.append(new)
        }
        order = newOrder
        oldestAvailable = counter
    }

    private func nextToken() -> ChangeToken {
        counter += 1
        return Self.token(counter)
    }

    private func record(_ change: PersistentChange) { changes.append(change) }

    static func token(_ n: Int) -> ChangeToken { ChangeToken(data: Data(String(n).utf8)) }
    static func number(_ token: ChangeToken) -> Int { Int(String(decoding: token.data, as: UTF8.self)) ?? -1 }

    // MARK: PhotosSource

    public nonisolated func authorizationStatus() -> PhotosAuthorization { .authorized }
    public func requestAuthorization() async -> PhotosAuthorization { authorization }

    public func currentChangeToken() async throws -> ChangeToken { Self.token(counter) }

    public func fetchAllAssets(after cursor: AssetCursor?, limit: Int) async throws -> AssetPage {
        guard authorization == .authorized else { throw PhotosSourceError.notAuthorized }
        let start = cursor.flatMap { Int($0.value) } ?? 0
        let slice = order.dropFirst(start).prefix(limit)
        let next = start + slice.count
        return AssetPage(assets: slice.compactMap { snapshots[$0] },
                         nextCursor: next < order.count ? AssetCursor(value: String(next)) : nil)
    }

    public func assets(localIds: [String]) async throws -> [AssetSnapshot] { localIds.compactMap { snapshots[$0] } }
    public func totalAssetCount() async throws -> Int { order.count }

    public func fetchPersistentChanges(since token: ChangeToken) async throws -> [PersistentChange] {
        let n = Self.number(token)
        guard n >= oldestAvailable else { throw PhotosSourceError.tokenExpired }
        return changes.filter { Self.number($0.token) > n }
    }

    public func cloudIdentifierMappings(localIds: [String]) async throws -> [String: String] {
        var result: [String: String] = [:]
        for id in localIds.prefix(500) { if let c = snapshots[id]?.cloudId { result[id] = c } }
        return result
    }

    public func localIdentifierMappings(cloudIds: [String]) async throws -> [String: String] {
        let wanted = Set(cloudIds)
        var result: [String: String] = [:]
        for (local, s) in snapshots { if let c = s.cloudId, wanted.contains(c) { result[c] = local } }
        return result
    }

    public func albums() async throws -> [AlbumSnapshot] { albumList }

    public func exportResource(localId: String, type: ResourceType, to destination: URL, control: ExportControl) async throws -> ExportedFile {
        if let remaining = failingExports[localId], remaining > 0 {
            failingExports[localId] = remaining - 1
            throw PhotosSourceError.networkError
        }
        guard let bytes = data[localId]?[type] else { throw PhotosSourceError.resourceNotFound(localId: localId, type: type) }
        guard control.record(bytes: bytes.count) else { throw PhotosSourceError.cancelled }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: destination)
        exportCount[localId, default: 0] += 1
        let h = TestFiles.hashes(of: bytes)
        return ExportedFile(url: destination, size: Int64(bytes.count), md5: h.md5, sha256: h.sha256)
    }

    public func readClassificationHeader(localId: String, type: ResourceType, spillTo: URL, control: ExportControl) async throws -> HeaderResult {
        headerReads.append(localId)
        guard snapshots[localId] != nil else { throw PhotosSourceError.assetNotFound(localId: localId) }
        return HeaderResult(metadata: headerMetadata[localId] ?? .empty, isConclusive: true, completeFile: nil)
    }

    public func adjustmentDataHash(localId: String) async throws -> String? { adjustmentHashes[localId] }

    public func exports(of localId: String) -> Int { exportCount[localId] ?? 0 }
}
