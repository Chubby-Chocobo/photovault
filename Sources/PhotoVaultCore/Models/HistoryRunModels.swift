import Foundation

/// One backfill run with the latest outcome of each of its files.
public struct BackfillRunRow: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var trigger: BackfillTrigger
    /// The destination of a per-destination run (`destinationAdded`, `recovery`).
    public var destinationId: DestinationID?
    public var startedAt: Date
    /// Nil while a file of the run is still waiting or uploading.
    public var finishedAt: Date?
    /// Built from jobs that existed before history was recorded.
    public var approximate: Bool
    /// The latest outcome of each file of the run.
    public var totals: [TransferOutcome: OutcomeTotal]
    /// Files of the run still pending or uploading.
    public var waiting: Int
    /// Files of the run that are deferred or skipped now, whether or not history saw them fail (it began later).
    public var retryable: Int

    public init(
        id: Int64, trigger: BackfillTrigger, destinationId: DestinationID?, startedAt: Date, finishedAt: Date?, approximate: Bool,
        totals: [TransferOutcome: OutcomeTotal] = [:], waiting: Int = 0, retryable: Int = 0
    ) {
        self.id = id
        self.trigger = trigger
        self.destinationId = destinationId
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.approximate = approximate
        self.totals = totals
        self.waiting = waiting
        self.retryable = retryable
    }
}

/// Where one file stands at one destination now, with its latest integrity result.
public struct FileDestinationStatus: Hashable, Sendable, Identifiable {
    public var destinationId: DestinationID
    public var resType: ResourceType
    public var state: JobState
    public var reason: JobStateReason?
    public var detail: String?
    /// Drive file id, or the path under a folder destination's root.
    public var remoteId: String?
    public var checkedAt: Date?
    public var checkResult: IntegrityCheckResult?

    public var id: String { "\(destinationId.rawValue)|\(resType.rawValue)" }

    public init(
        destinationId: DestinationID, resType: ResourceType, state: JobState, reason: JobStateReason? = nil, detail: String? = nil,
        remoteId: String? = nil, checkedAt: Date? = nil, checkResult: IntegrityCheckResult? = nil
    ) {
        self.destinationId = destinationId
        self.resType = resType
        self.state = state
        self.reason = reason
        self.detail = detail
        self.remoteId = remoteId
        self.checkedAt = checkedAt
        self.checkResult = checkResult
    }
}

/// Which files of an import a list shows. Empty members do not filter.
public struct ImportItemFilter: Hashable, Sendable {
    public var sourceId: SourceID
    public var states: Set<ImportItemState>
    /// Part of the relative path, any case.
    public var search: String

    public init(sourceId: SourceID, states: Set<ImportItemState> = [], search: String = "") {
        self.sourceId = sourceId
        self.states = states
        self.search = search
    }
}

/// One file found by an import, with the backed-up file a duplicate matched.
public struct ImportItemRow: Identifiable, Hashable, Sendable {
    public var relativePath: String
    public var state: ImportItemState
    /// Machine reason (`read`, `missing`, `hash`, `companion`), never a path.
    public var reason: String?
    public var sizeBytes: Int64
    /// The asset the file became (imported) or matched (duplicate).
    public var assetKey: AssetKey?
    /// Name and capture time of the backed-up file a duplicate matched.
    public var duplicateOfName: String?
    public var duplicateOfCapturedAt: Date?

    public var id: String { relativePath }

    public init(
        relativePath: String, state: ImportItemState, reason: String?, sizeBytes: Int64, assetKey: AssetKey?,
        duplicateOfName: String? = nil, duplicateOfCapturedAt: Date? = nil
    ) {
        self.relativePath = relativePath
        self.state = state
        self.reason = reason
        self.sizeBytes = sizeBytes
        self.assetKey = assetKey
        self.duplicateOfName = duplicateOfName
        self.duplicateOfCapturedAt = duplicateOfCapturedAt
    }
}

/// One import with the files and bytes of each item state.
public struct ImportRunRow: Identifiable, Hashable, Sendable {
    public var source: SourceRecord
    public var totals: [ImportItemState: OutcomeTotal]
    /// Uploads of its files that are deferred or skipped now.
    public var failedUploads: Int

    public var id: SourceID { source.id }

    public init(source: SourceRecord, totals: [ImportItemState: OutcomeTotal], failedUploads: Int = 0) {
        self.source = source
        self.totals = totals
        self.failedUploads = failedUploads
    }
}
