import Foundation

/// Photos authorization (FR-04).
public enum PhotosAuthorization: String, Codable, Sendable {
    case notDetermined, restricted, denied, authorized, limited

    public var allowsReading: Bool { self == .authorized }
}

/// Opaque, archivable PhotoKit change token.
public struct ChangeToken: Hashable, Codable, Sendable {
    public var data: Data
    public init(data: Data) { self.data = data }
}

/// Opaque resumable scan cursor; only the source that produced it can interpret it.
public struct AssetCursor: Hashable, Codable, Sendable {
    public var value: String
    public init(value: String) { self.value = value }
}

public struct AssetPage: Sendable {
    public var assets: [AssetSnapshot]
    /// Nil when the scan reached the end.
    public var nextCursor: AssetCursor?

    public init(assets: [AssetSnapshot], nextCursor: AssetCursor?) {
        self.assets = assets
        self.nextCursor = nextCursor
    }
}

/// One `PHPersistentChange`, committed in its own transaction with its own token (FR-12).
public struct PersistentChange: Sendable {
    public var token: ChangeToken
    public var insertedLocalIds: [String]
    public var updatedLocalIds: [String]
    public var deletedLocalIds: [String]
    /// Album membership or titles changed; `album_member` must be refreshed.
    public var albumsChanged: Bool

    public init(token: ChangeToken, insertedLocalIds: [String] = [], updatedLocalIds: [String] = [],
                deletedLocalIds: [String] = [], albumsChanged: Bool = false) {
        self.token = token
        self.insertedLocalIds = insertedLocalIds
        self.updatedLocalIds = updatedLocalIds
        self.deletedLocalIds = deletedLocalIds
        self.albumsChanged = albumsChanged
    }
}

/// A file written by an export, hashed while streaming (FR-30).
public struct ExportedFile: Hashable, Sendable {
    public var url: URL
    public var size: Int64
    public var md5: String
    public var sha256: String

    public init(url: URL, size: Int64, md5: String, sha256: String) {
        self.url = url
        self.size = size
        self.md5 = md5
        self.sha256 = sha256
    }
}

/// Result of reading just enough of a primary photo to classify it (FR-20).
public struct HeaderResult: Sendable {
    /// Metadata when it could be determined (present or proven absent); nil when the read ended
    /// before the metadata was complete.
    public var metadata: CaptureMetadata?
    /// Whether the metadata answer is final. `false` means "could not decide".
    public var isConclusive: Bool
    /// The full file when the whole resource arrived; kept as staging so it is not downloaded twice.
    public var completeFile: ExportedFile?

    public init(metadata: CaptureMetadata?, isConclusive: Bool, completeFile: ExportedFile?) {
        self.metadata = metadata
        self.isConclusive = isConclusive
        self.completeFile = completeFile
    }
}

/// Synchronous control shared between the PhotoKit data handler and the engine. The handler
/// calls `record(bytes:)` for every chunk on PhotoKit's queue; the engine sets `cancel()`.
public final class ExportControl: @unchecked Sendable {
    public static let defaultCheckpointBytes: Int64 = 256 << 20

    private let lock = NSLock()
    private var cancelled = false
    private var received: Int64 = 0
    private var nextCheckpoint: Int64
    private let checkpointBytes: Int64
    private let checkpoint: @Sendable (Int64) -> Bool
    private var progress: TransferSink?

    /// - Parameter checkpoint: called synchronously every `checkpointBytes` with the bytes received
    ///   so far; return `false` to cancel. Must not block.
    public init(checkpointBytes: Int64 = ExportControl.defaultCheckpointBytes,
                checkpoint: @escaping @Sendable (Int64) -> Bool = { _ in true }) {
        self.checkpointBytes = checkpointBytes
        self.nextCheckpoint = checkpointBytes
        self.checkpoint = checkpoint
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public var bytesReceived: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    /// Reports the bytes received so far to `sink` with every chunk (the status line).
    public func setProgress(_ sink: TransferSink?) {
        lock.lock()
        progress = sink
        lock.unlock()
    }

    /// Records a chunk. Returns `false` when the export must stop.
    public func record(bytes: Int) -> Bool {
        lock.lock()
        received += Int64(bytes)
        let total = received
        let sink = progress
        var runCheckpoint = false
        if total >= nextCheckpoint {
            nextCheckpoint = total + checkpointBytes
            runCheckpoint = true
        }
        let stop = cancelled
        lock.unlock()
        sink?.report(total)
        if stop { return false }
        if runCheckpoint, !checkpoint(total) {
            cancel()
            return false
        }
        return true
    }
}

/// Read-only access to the system Photos library. Errors are `PhotosSourceError`.
public protocol PhotosSource: Sendable {
    func authorizationStatus() -> PhotosAuthorization
    func requestAuthorization() async -> PhotosAuthorization
    func currentChangeToken() async throws -> ChangeToken
    /// Every asset, including hidden assets and all burst frames (FR-10), in a stable order.
    func fetchAllAssets(after cursor: AssetCursor?, limit: Int) async throws -> AssetPage
    func assets(localIds: [String]) async throws -> [AssetSnapshot]
    func totalAssetCount() async throws -> Int
    /// Changes after `token`, oldest first. Throws `.tokenExpired` or `.changeDetailsUnavailable`.
    func fetchPersistentChanges(since token: ChangeToken) async throws -> [PersistentChange]
    /// Local → cloud identifiers for up to 500 local IDs (FR-53). Unknown IDs are absent.
    func cloudIdentifierMappings(localIds: [String]) async throws -> [String: String]
    /// Cloud → local identifiers (spec 8.1 re-attach). Unknown IDs are absent.
    func localIdentifierMappings(cloudIds: [String]) async throws -> [String: String]
    func albums() async throws -> [AlbumSnapshot]
    /// Streams one resource to `destination`, hashing while writing. Honors `control`.
    func exportResource(localId: String, type: ResourceType, to destination: URL, control: ExportControl) async throws -> ExportedFile
    /// Reads the primary photo until TIFF Make/Model are known or proven absent (FR-20).
    func readClassificationHeader(localId: String, type: ResourceType, spillTo: URL, control: ExportControl) async throws -> HeaderResult
    /// SHA-256 of the `.adjustmentData` resource, or nil when the asset has none (FR-46).
    func adjustmentDataHash(localId: String) async throws -> String?
}

/// Reads capture metadata from an exported file (FR-34).
public protocol MetadataReading: Sendable {
    func metadata(of file: URL, uti: String, mediaType: MediaType) -> CaptureMetadata
}
