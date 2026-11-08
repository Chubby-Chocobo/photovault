import Foundation

/// Which content hash a destination verifies.
public enum ContentHashKind: String, Codable, Sendable {
    case md5, sha256
}

public struct DestinationCapabilities: Hashable, Sendable {
    public var supportsViews: Bool
    public var supportsAppProperties: Bool
    public var supportsQuota: Bool
    public var supportsDescription: Bool
    /// IDs must be reserved with `reserveIds` and persisted before any create.
    public var reservesIds: Bool
    public var verifiedHash: ContentHashKind

    public init(supportsViews: Bool, supportsAppProperties: Bool, supportsQuota: Bool,
                supportsDescription: Bool, reservesIds: Bool, verifiedHash: ContentHashKind) {
        self.supportsViews = supportsViews
        self.supportsAppProperties = supportsAppProperties
        self.supportsQuota = supportsQuota
        self.supportsDescription = supportsDescription
        self.reservesIds = reservesIds
        self.verifiedHash = verifiedHash
    }
}

public enum ReservedIdKind: String, Sendable {
    case files, shortcuts
}

/// A folder at a destination.
public struct RemoteFolderRef: Hashable, Codable, Sendable {
    /// Logical path without display names (spec 8.2), e.g. `camera/2026/11/2026-11-08`. Empty = root.
    public var logicalPath: String
    /// Drive folder ID, or the relative path for local destinations.
    public var remoteId: String
    /// Relative display path from the root (local destinations), e.g. `2026/11/2026-11-08 Đà Lạt`.
    public var displayPath: String

    public init(logicalPath: String, remoteId: String, displayPath: String) {
        self.logicalPath = logicalPath
        self.remoteId = remoteId
        self.displayPath = displayPath
    }

    public static func root(remoteId: String) -> RemoteFolderRef {
        RemoteFolderRef(logicalPath: "", remoteId: remoteId, displayPath: "")
    }
}

public struct FolderRequest: Hashable, Sendable {
    public var logicalPath: String
    /// Display name of this folder (last path component, already sanitized).
    public var name: String
    public var parent: RemoteFolderRef
    /// Persisted before the call when `capabilities.reservesIds`.
    public var reservedId: String?
    public var appProperties: [String: String]

    public init(logicalPath: String, name: String, parent: RemoteFolderRef, reservedId: String?, appProperties: [String: String]) {
        self.logicalPath = logicalPath
        self.name = name
        self.parent = parent
        self.reservedId = reservedId
        self.appProperties = appProperties
    }
}

/// A staged file to write.
public struct StagedContent: Hashable, Sendable {
    public var file: URL
    public var size: Int64
    public var md5: String
    public var sha256: String

    public init(file: URL, size: Int64, md5: String, sha256: String) {
        self.file = file
        self.size = size
        self.md5 = md5
        self.sha256 = sha256
    }

    public init(_ exported: ExportedFile) {
        self.init(file: exported.url, size: exported.size, md5: exported.md5, sha256: exported.sha256)
    }

    public func hash(_ kind: ContentHashKind) -> String { kind == .md5 ? md5 : sha256 }
}

public struct UploadRequest: Hashable, Sendable {
    public var job: JobIdentity
    /// Trace id for logs.
    public var jobId: Int64?
    public var kind: ResourceKind
    /// Persisted before the call when `capabilities.reservesIds`.
    public var reservedRemoteId: String?
    public var parent: RemoteFolderRef
    public var fileName: String
    public var content: StagedContent
    public var appProperties: [String: String]
    public var description: String?
    /// Hash the app last wrote at this destination, if any (FR-73 overwrite rule).
    public var expectedPriorHash: String?

    public init(job: JobIdentity, jobId: Int64?, kind: ResourceKind, reservedRemoteId: String?, parent: RemoteFolderRef,
                fileName: String, content: StagedContent, appProperties: [String: String] = [:],
                description: String? = nil, expectedPriorHash: String? = nil) {
        self.job = job
        self.jobId = jobId
        self.kind = kind
        self.reservedRemoteId = reservedRemoteId
        self.parent = parent
        self.fileName = fileName
        self.content = content
        self.appProperties = appProperties
        self.description = description
        self.expectedPriorHash = expectedPriorHash
    }
}

/// A resumable session to persist before the first byte is sent (FR-44). The URI is a secret.
public struct SessionCheckpoint: Hashable, Codable, Sendable, CustomStringConvertible {
    public var sessionRef: String
    public var md5: String
    public var totalBytes: Int64

    public init(sessionRef: String, md5: String, totalBytes: Int64) {
        self.sessionRef = sessionRef
        self.md5 = md5
        self.totalBytes = totalBytes
    }

    public var description: String { "SessionCheckpoint(<redacted>, bytes: \(totalBytes))" }
}

public struct UploadResult: Hashable, Sendable {
    public var remoteId: String
    /// May differ from the requested name (local conflict copies, FR-73).
    public var finalName: String
    /// Hash of the content now at the destination (MD5 for Drive, SHA-256 for local).
    public var verifiedHash: String
    public var parentIds: [String]
    public var trashed: Bool
    public var size: Int64

    public init(remoteId: String, finalName: String, verifiedHash: String, parentIds: [String], trashed: Bool, size: Int64) {
        self.remoteId = remoteId
        self.finalName = finalName
        self.verifiedHash = verifiedHash
        self.parentIds = parentIds
        self.trashed = trashed
        self.size = size
    }
}

public enum RemoteItemKind: String, Codable, Sendable {
    case file, folder, shortcut
}

/// An item listed or probed at a destination.
public struct RemoteItem: Hashable, Codable, Sendable {
    public var remoteId: String
    public var name: String
    public var parentIds: [String]
    public var kind: RemoteItemKind
    public var size: Int64?
    public var md5: String?
    public var sha256: String?
    public var appProperties: [String: String]
    public var shortcutTargetId: String?
    public var trashed: Bool
    /// Local destinations: path relative to the root.
    public var relativePath: String?

    public init(remoteId: String, name: String, parentIds: [String], kind: RemoteItemKind, size: Int64? = nil,
                md5: String? = nil, sha256: String? = nil, appProperties: [String: String] = [:],
                shortcutTargetId: String? = nil, trashed: Bool = false, relativePath: String? = nil) {
        self.remoteId = remoteId
        self.name = name
        self.parentIds = parentIds
        self.kind = kind
        self.size = size
        self.md5 = md5
        self.sha256 = sha256
        self.appProperties = appProperties
        self.shortcutTargetId = shortcutTargetId
        self.trashed = trashed
        self.relativePath = relativePath
    }
}

public struct Quota: Hashable, Sendable {
    public var totalBytes: Int64?
    public var usedBytes: Int64?
    public var availableBytes: Int64?

    public init(totalBytes: Int64?, usedBytes: Int64?, availableBytes: Int64?) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.availableBytes = availableBytes
    }
}

/// A backup destination (spec 8.9.1). There is deliberately no delete operation.
/// All methods throw `DestinationError`.
public protocol Destination: Sendable {
    var id: DestinationID { get }
    var capabilities: DestinationCapabilities { get }

    func checkAvailability() async -> DestinationStatus
    /// Pre-generates IDs (Drive `generateIds`). Local destinations return fresh UUID strings.
    func reserveIds(count: Int, kind: ReservedIdKind) async throws -> [String]
    /// Creates the folder if missing and returns it; idempotent for the same logical path.
    func ensureFolder(_ request: FolderRequest) async throws -> RemoteFolderRef
    /// Uploads a new file. `onSession` is awaited before the first byte is sent.
    func upload(_ request: UploadRequest, onSession: @Sendable (SessionCheckpoint) async throws -> Void) async throws -> UploadResult
    /// Resumes a persisted session; throws `.sessionExpired` when the session is gone.
    func resumeUpload(_ request: UploadRequest, session: SessionCheckpoint,
                      onSession: @Sendable (SessionCheckpoint) async throws -> Void) async throws -> UploadResult
    /// Current state of an item, nil when it does not exist (FR-44 "files.get first").
    func probe(remoteId: String) async throws -> RemoteItem?
    /// Replaces the content of an existing file in place (edited, sidecar, checksum repair).
    /// Local destinations refuse when the on-disk hash differs from `request.expectedPriorHash`.
    func replaceContent(remoteId: String, _ request: UploadRequest) async throws -> UploadResult
    func move(remoteId: String, name: String, from: RemoteFolderRef, to: RemoteFolderRef) async throws -> RemoteItem
    func renameFolder(_ folder: RemoteFolderRef, newName: String) async throws -> RemoteFolderRef
    /// Items the app created under `folder` (nil = the whole backup tree).
    func list(under folder: RemoteFolderRef?) -> AsyncThrowingStream<RemoteItem, any Error>
    func quota() async throws -> Quota?
}

public struct ShortcutRequest: Hashable, Sendable {
    public var reservedId: String
    public var targetId: String
    public var parent: RemoteFolderRef
    public var name: String
    public var appProperties: [String: String]

    public init(reservedId: String, targetId: String, parent: RemoteFolderRef, name: String, appProperties: [String: String]) {
        self.reservedId = reservedId
        self.targetId = targetId
        self.parent = parent
        self.name = name
        self.appProperties = appProperties
    }
}

/// Shortcut views (Drive only, FR-100..103).
public protocol ViewDestination: Destination {
    func createShortcut(_ request: ShortcutRequest) async throws -> RemoteItem
    func moveShortcut(remoteId: String, from: RemoteFolderRef, to: RemoteFolderRef) async throws -> RemoteItem
    /// Trashes a shortcut. Only shortcuts may be trashed by the app.
    func trashShortcut(remoteId: String) async throws
}

public enum RootCheck: Hashable, Sendable {
    case ok(RemoteItem)
    case missing
    case trashed
}

/// Root management and owner-requested restores (Drive only).
public protocol RootManaging: Destination {
    /// Existing roots carrying `pvRoot=1` (FR-01 step 3).
    func findRoots() async throws -> [RemoteItem]
    func checkRoot(remoteId: String) async throws -> RootCheck
    func createRoot(reservedId: String, name: String, appProperties: [String: String]) async throws -> RemoteItem
    func renameRoot(remoteId: String, newName: String) async throws -> RemoteItem
    /// "Khôi phục giúp tôi": untrash an item the app created (FR-47).
    func untrash(remoteId: String) async throws -> RemoteItem
    /// Updates `description` and app properties of an app-created item (FR-43).
    func updateMetadata(remoteId: String, description: String?, appProperties: [String: String]) async throws
}
