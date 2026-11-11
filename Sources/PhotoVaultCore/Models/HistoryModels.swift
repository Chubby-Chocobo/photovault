import Foundation

/// The outcome one `transfer_event` row records: the end of an upload, a give-up, a skip or a cancel.
public enum TransferOutcome: String, Codable, Sendable, CaseIterable {
    case uploaded, updated, failed, skipped, cancelled
}

/// Why a backfill run exists. `beforeHistory` holds the backfill jobs that existed before history was recorded.
public enum BackfillTrigger: String, Codable, Sendable, CaseIterable {
    case library, settings, destinationAdded, recovery, beforeHistory

    /// Runs of these causes belong to one destination; the others span every destination.
    public var isPerDestination: Bool { self == .destinationAdded || self == .recovery }
}

/// The latest integrity result of one file at one destination.
public enum IntegrityCheckResult: String, Codable, Sendable, CaseIterable {
    /// Present with the expected size.
    case intact
    /// Present and re-hashed: the content is the one uploaded.
    case hashVerified
    case missing, sizeMismatch, hashMismatch

    public var isProblem: Bool { self == .missing || self == .sizeMismatch || self == .hashMismatch }
}

/// The kind of file a history list keeps.
public enum HistoryMediaFilter: String, Sendable, CaseIterable {
    case all, photo, video, raw
}

/// Which transfer events a history list shows. Empty or nil members do not filter.
public struct TransferEventFilter: Hashable, Sendable {
    public enum Scope: Hashable, Sendable {
        /// Files of the Photos library.
        case photos
        /// Files of one backfill run.
        case run(Int64)
    }

    public var scope: Scope
    /// Part of the file name, any case.
    public var search: String
    public var destinationId: DestinationID?
    public var outcomes: Set<TransferOutcome>
    public var media: HistoryMediaFilter
    /// When the event happened: `from` inclusive, `until` exclusive.
    public var from: Date?
    public var until: Date?
    /// When the photo was taken: `capturedFrom` inclusive, `capturedUntil` exclusive.
    public var capturedFrom: Date?
    public var capturedUntil: Date?
    /// Only files deleted from the Photos library whose backup is kept.
    public var deletedFromLibraryOnly: Bool

    public init(
        scope: Scope = .photos, search: String = "", destinationId: DestinationID? = nil, outcomes: Set<TransferOutcome> = [],
        media: HistoryMediaFilter = .all, from: Date? = nil, until: Date? = nil, capturedFrom: Date? = nil,
        capturedUntil: Date? = nil, deletedFromLibraryOnly: Bool = false
    ) {
        self.scope = scope
        self.search = search
        self.destinationId = destinationId
        self.outcomes = outcomes
        self.media = media
        self.from = from
        self.until = until
        self.capturedFrom = capturedFrom
        self.capturedUntil = capturedUntil
        self.deletedFromLibraryOnly = deletedFromLibraryOnly
    }
}

/// Keyset position in a list ordered newest first: the last row of the previous page.
public struct HistoryCursor: Hashable, Sendable {
    public var at: Date
    public var id: Int64

    public init(at: Date, id: Int64) {
        self.at = at
        self.id = id
    }
}

/// One row of a transfer history list, with what the list shows of its file.
public struct TransferEventRow: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var at: Date
    /// Copied from an older job when history began: the time is the job's last change, not the upload's.
    public var approximate: Bool
    public var jobId: Int64
    public var destinationId: DestinationID
    public var assetKey: AssetKey
    public var resType: ResourceType
    public var sourceId: SourceID
    public var origin: JobOrigin
    public var runId: Int64?
    public var outcome: TransferOutcome
    public var bytes: Int64
    public var reason: JobStateReason?
    /// Short error code of the last failure (a `DestinationError` case name), never a path.
    public var detail: String?
    /// The file's original name; empty when the resource row is gone.
    public var fileName: String
    public var mediaType: MediaType
    public var isRaw: Bool
    public var capturedAt: Date?
    /// Set when the photo was deleted from the library; the backup is kept.
    public var deletedFromLibraryAt: Date?

    public var cursor: HistoryCursor { HistoryCursor(at: at, id: id) }

    public init(
        id: Int64, at: Date, approximate: Bool, jobId: Int64, destinationId: DestinationID, assetKey: AssetKey,
        resType: ResourceType, sourceId: SourceID, origin: JobOrigin, runId: Int64?, outcome: TransferOutcome, bytes: Int64,
        reason: JobStateReason?, detail: String?, fileName: String, mediaType: MediaType, isRaw: Bool, capturedAt: Date?,
        deletedFromLibraryAt: Date?
    ) {
        self.id = id
        self.at = at
        self.approximate = approximate
        self.jobId = jobId
        self.destinationId = destinationId
        self.assetKey = assetKey
        self.resType = resType
        self.sourceId = sourceId
        self.origin = origin
        self.runId = runId
        self.outcome = outcome
        self.bytes = bytes
        self.reason = reason
        self.detail = detail
        self.fileName = fileName
        self.mediaType = mediaType
        self.isRaw = isRaw
        self.capturedAt = capturedAt
        self.deletedFromLibraryAt = deletedFromLibraryAt
    }
}

/// Files and bytes of one outcome.
public struct OutcomeTotal: Hashable, Sendable {
    public var files: Int
    public var bytes: Int64

    public init(files: Int = 0, bytes: Int64 = 0) {
        self.files = files
        self.bytes = bytes
    }
}

/// Uploaded and updated files of one 15-minute slot (UTC), for the daily timeline.
public struct TimelineSlot: Hashable, Sendable {
    public var start: Date
    public var files: Int
    public var bytes: Int64

    public init(start: Date, files: Int, bytes: Int64) {
        self.start = start
        self.files = files
        self.bytes = bytes
    }
}
