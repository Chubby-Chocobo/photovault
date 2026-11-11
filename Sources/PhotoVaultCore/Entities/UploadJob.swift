import Foundation

/// Row of `upload_job` (spec 8.2), unique per (destination, asset, resource type).
public struct UploadJob: Hashable, Codable, Sendable {
    /// Row id, used as the trace id in logs (NFR-07). Nil before insert.
    public var id: Int64?
    public var destinationId: DestinationID
    public var assetKey: AssetKey
    public var resType: ResourceType
    public var kind: ResourceKind
    public var origin: JobOrigin
    public var state: JobState
    public var stateReason: JobStateReason?
    public var remoteLogicalParent: String?
    public var remoteName: String?
    /// Drive file ID (reserved with `generateIds` and persisted before any create) or the local
    /// logical file path.
    public var remoteId: String?
    /// Resumable session URI. Secret: never logged.
    public var sessionRef: String?
    public var sessionMd5: String?
    /// Hash of the content the app last wrote (MD5 for Drive, SHA-256 for local).
    public var uploadedHash: String?
    /// Generation the destination must end up with.
    public var targetGen: Int
    /// Generation known to be at the destination.
    public var doneGen: Int
    /// Generation being uploaded, captured at `pending → uploading`.
    public var uploadingGen: Int?
    public var mismatchCount: Int
    /// Item-level upload failures only (8.14).
    public var attempts: Int
    public var nextAttemptAt: Date?
    public var deferredSince: Date?
    public var lastError: String?
    public var updatedAt: Date
    /// The backfill run the job joined when it was created or reinstated as a backfill job; nil otherwise.
    public var backfillRunId: Int64?

    public init(
        id: Int64? = nil, destinationId: DestinationID, assetKey: AssetKey, resType: ResourceType,
        origin: JobOrigin, state: JobState = .pending, stateReason: JobStateReason? = nil,
        remoteLogicalParent: String? = nil, remoteName: String? = nil, remoteId: String? = nil,
        sessionRef: String? = nil, sessionMd5: String? = nil, uploadedHash: String? = nil,
        targetGen: Int = 1, doneGen: Int = 0, uploadingGen: Int? = nil, mismatchCount: Int = 0,
        attempts: Int = 0, nextAttemptAt: Date? = nil, deferredSince: Date? = nil, lastError: String? = nil,
        updatedAt: Date, backfillRunId: Int64? = nil
    ) {
        self.id = id
        self.destinationId = destinationId
        self.assetKey = assetKey
        self.resType = resType
        self.kind = resType.kind
        self.origin = origin
        self.state = state
        self.stateReason = stateReason
        self.remoteLogicalParent = remoteLogicalParent
        self.remoteName = remoteName
        self.remoteId = remoteId
        self.sessionRef = sessionRef
        self.sessionMd5 = sessionMd5
        self.uploadedHash = uploadedHash
        self.targetGen = targetGen
        self.doneGen = doneGen
        self.uploadingGen = uploadingGen
        self.mismatchCount = mismatchCount
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.deferredSince = deferredSince
        self.lastError = lastError
        self.updatedAt = updatedAt
        self.backfillRunId = backfillRunId
    }

    public var identity: JobIdentity { JobIdentity(destinationId: destinationId, assetKey: assetKey, resType: resType) }

    /// The destination already holds the newest generation.
    public var isUpToDate: Bool { state == .done && doneGen >= targetGen }
}

/// Unique key of an upload job.
public struct JobIdentity: Hashable, Codable, Sendable {
    public var destinationId: DestinationID
    public var assetKey: AssetKey
    public var resType: ResourceType

    public init(destinationId: DestinationID, assetKey: AssetKey, resType: ResourceType) {
        self.destinationId = destinationId
        self.assetKey = assetKey
        self.resType = resType
    }
}
