import Foundation

/// Row of the `resource` table (spec 8.2). Sidecars have no resource row.
public struct ResourceRecord: Hashable, Codable, Sendable {
    public var assetKey: AssetKey
    public var type: ResourceType
    public var kind: ResourceKind
    public var isRaw: Bool
    public var originalFilename: String
    public var uti: String
    public var sizeBytes: Int64?
    /// Content generation; increments when the edited content changes (FR-46).
    public var contentGen: Int
    public var md5: String?
    public var sha256: String?
    /// Generation of the file currently in staging.
    public var stagingGen: Int
    public var stagingPath: String?
    public var stagingState: StagingState
    public var exportCount: Int
    /// Single counter for export errors (FR-23).
    public var exportAttempts: Int
    public var exportDeferredSince: Date?
    public var nextExportAttemptAt: Date?
    public var bytesReceivedAtCancel: Int64?
    public var diskCancelCount: Int
    /// Set when the disk guard proved the file cannot fit (FR-31).
    public var tooLargeForDisk: Bool
    public var lastUsedAt: Date?
    public var lastError: String?

    public init(
        assetKey: AssetKey, type: ResourceType, isRaw: Bool = false, originalFilename: String, uti: String,
        sizeBytes: Int64? = nil, contentGen: Int = 1, md5: String? = nil, sha256: String? = nil,
        stagingGen: Int = 0, stagingPath: String? = nil, stagingState: StagingState = .none,
        exportCount: Int = 0, exportAttempts: Int = 0, exportDeferredSince: Date? = nil,
        nextExportAttemptAt: Date? = nil, bytesReceivedAtCancel: Int64? = nil, diskCancelCount: Int = 0,
        tooLargeForDisk: Bool = false, lastUsedAt: Date? = nil, lastError: String? = nil
    ) {
        self.assetKey = assetKey
        self.type = type
        self.kind = type.kind
        self.isRaw = isRaw
        self.originalFilename = originalFilename
        self.uti = uti
        self.sizeBytes = sizeBytes
        self.contentGen = contentGen
        self.md5 = md5
        self.sha256 = sha256
        self.stagingGen = stagingGen
        self.stagingPath = stagingPath
        self.stagingState = stagingState
        self.exportCount = exportCount
        self.exportAttempts = exportAttempts
        self.exportDeferredSince = exportDeferredSince
        self.nextExportAttemptAt = nextExportAttemptAt
        self.bytesReceivedAtCancel = bytesReceivedAtCancel
        self.diskCancelCount = diskCancelCount
        self.tooLargeForDisk = tooLargeForDisk
        self.lastUsedAt = lastUsedAt
        self.lastError = lastError
    }

    /// Ready for upload of the current content.
    public var isReadyForCurrentContent: Bool { stagingState == .ready && stagingGen == contentGen }
}
