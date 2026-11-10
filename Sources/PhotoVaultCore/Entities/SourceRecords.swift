import Foundation

/// Source configuration stored as `config_json`.
public struct SourceConfig: Hashable, Codable, Sendable {
    /// Read-only security-scoped bookmark of the picked folder.
    public var bookmark: Data?
    /// Account the cloud import reads from (email), for display only; never logged.
    public var account: String?
    /// Google Drive: the picked file and folder ids. Dropbox: one root path (`""` = the whole account).
    public var remoteItems: [String]?
    /// Name written to sidecars. Cloud imports set it to a name that does not depend on the app language
    /// (the picked folder's name, or the provider's); nil means the display name.
    public var sidecarName: String?

    public init(bookmark: Data? = nil, account: String? = nil, remoteItems: [String]? = nil, sidecarName: String? = nil) {
        self.bookmark = bookmark
        self.account = account
        self.remoteItems = remoteItems
        self.sidecarName = sidecarName
    }
}

/// Row of `source`: a one-time import job (or, later, a continuous source).
public struct SourceRecord: Hashable, Codable, Sendable {
    public var id: SourceID
    public var kind: SourceKind
    public var mode: SourceMode
    public var displayName: String
    public var config: SourceConfig
    public var status: SourceStatus
    /// Short machine reason, never a path or file name.
    public var statusReason: String?
    public var createdAt: Date
    /// When the folder listing finished.
    public var listedAt: Date?
    public var finishedAt: Date?

    public init(id: SourceID, kind: SourceKind, mode: SourceMode, displayName: String, config: SourceConfig = SourceConfig(),
                status: SourceStatus, statusReason: String? = nil, createdAt: Date, listedAt: Date? = nil, finishedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.mode = mode
        self.displayName = displayName
        self.config = config
        self.status = status
        self.statusReason = statusReason
        self.createdAt = createdAt
        self.listedAt = listedAt
        self.finishedAt = finishedAt
    }

    /// The name sidecars carry for this import.
    public var sidecarName: String { config.sidecarName ?? displayName }
}

public enum ImportItemState: String, Codable, Sendable, CaseIterable {
    case pending, imported, duplicate, unsupported, failed, cancelled
}

/// Row of `import_item`: one file found in a source.
public struct ImportItem: Hashable, Codable, Sendable {
    public var sourceId: SourceID
    public var relativePath: String
    public var groupKey: String
    public var uti: String
    public var sizeBytes: Int64
    public var createdAtFS: Date?
    public var modifiedAtFS: Date?
    public var state: ImportItemState
    public var assetKey: AssetKey?
    public var isPrimary: Bool
    public var dateSource: DateSource?
    public var reason: String?

    public init(sourceId: SourceID, relativePath: String, groupKey: String, uti: String, sizeBytes: Int64,
                createdAtFS: Date? = nil, modifiedAtFS: Date? = nil, state: ImportItemState = .pending,
                assetKey: AssetKey? = nil, isPrimary: Bool = false, dateSource: DateSource? = nil, reason: String? = nil) {
        self.sourceId = sourceId
        self.relativePath = relativePath
        self.groupKey = groupKey
        self.uti = uti
        self.sizeBytes = sizeBytes
        self.createdAtFS = createdAtFS
        self.modifiedAtFS = modifiedAtFS
        self.state = state
        self.assetKey = assetKey
        self.isPrimary = isPrimary
        self.dateSource = dateSource
        self.reason = reason
    }
}
