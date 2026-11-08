import Foundation

/// Upload job state (spec 8.3).
public enum JobState: String, Codable, Sendable, CaseIterable {
    case pending, uploading, done, deferred, skipped, cancelled, missingRemote

    /// Finished states for the "every original job finished" sidecar rule (FR-93).
    public var isFinished: Bool { self == .done || self == .skipped }
}

/// Why a job is deferred or skipped.
public enum JobStateReason: String, Codable, Sendable, CaseIterable {
    case uploadFailures
    case exportFailures
    case checksumMismatch
    case foreignFile
    case foreignModified
    case tooLargeForDisk
    case tooLargeForRule
    case permanentError
    case deferredTooLong
    case resourceMissing
}

/// Why a job exists; also its priority (lower value = earlier).
public enum JobOrigin: String, Codable, Sendable, CaseIterable, Comparable {
    case incremental, refresh, reupload, backfill, destinationBackfill

    public var priority: Int {
        switch self {
        case .incremental: 0
        case .refresh: 1
        case .reupload: 2
        case .backfill: 3
        case .destinationBackfill: 4
        }
    }

    /// Origins limited by the backfill token bucket and power gates (8.5).
    public var isRateLimited: Bool { self == .backfill || self == .destinationBackfill || self == .reupload }

    public static func < (lhs: JobOrigin, rhs: JobOrigin) -> Bool { lhs.priority < rhs.priority }
}

/// Staging state of a resource (spec 8.3).
public enum StagingState: String, Codable, Sendable, CaseIterable {
    case none, exporting, ready
}
