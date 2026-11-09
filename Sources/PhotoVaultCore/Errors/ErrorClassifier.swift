import Foundation

/// Error classes of spec 8.14.
public enum ErrorClass: Hashable, Sendable {
    /// Change the destination status (or back off the destination); jobs return to `pending`
    /// without touching `attempts`.
    case destinationLevel(DestinationStatus?)
    /// Count against the job (`attempts`) or resource (`export_attempts`).
    case itemLevel
    /// Retry inside the current pass, at most `ErrorClassifier.transientRetries` times.
    case transient
    /// Mark `skipped` at once.
    case permanent(JobStateReason)
    /// Verification is needed before deciding (already-exists, lost session).
    case verify
}

public enum ErrorClassifier {
    public static let transientRetries = 3
    /// `DestinationError.itemRejected` reasons starting with this prefix are permanent (skipped at once).
    public static let permanentReasonPrefix = "permanent:"
    /// Consecutive 5xx or repeated 429 responses after which the whole destination backs off.
    public static let destinationBackoffThreshold = 3

    public static func classify(_ error: DestinationError, consecutiveFailures: Int = 0) -> ErrorClass {
        switch error {
        case .unauthorized, .reauthRequired: .destinationLevel(.error(.reauthRequired))
        case .offline: .destinationLevel(.unavailable(.offline))
        case .bookmarkInvalid: .destinationLevel(.unavailable(.bookmarkInvalid))
        case .noSpace, .quotaExceeded: .destinationLevel(.paused(.full))
        case .dailyCapReached: .destinationLevel(.paused(.dailyCapReached))
        case .rootMissing: .destinationLevel(.paused(.rootMissing))
        case .rootTrashed: .destinationLevel(.paused(.rootTrashed))
        case .folderTrashed: .destinationLevel(.paused(.folderTrashed))
        case .rateLimited, .server:
            consecutiveFailures >= destinationBackoffThreshold ? .destinationLevel(nil) : .transient
        case .transient: .transient
        case .folderMissing, .alreadyExists, .sessionExpired: .verify
        case .itemRejected(let reason) where reason.hasPrefix(permanentReasonPrefix): .permanent(.permanentError)
        case .notFound, .checksumMismatch, .itemRejected: .itemLevel
        case .foreignFile: .permanent(.foreignFile)
        case .foreignModified: .permanent(.foreignModified)
        case .viewsNotPermitted: .permanent(.permanentError)
        }
    }

    public static func classify(_ error: PhotosSourceError) -> ErrorClass {
        switch error {
        case .notAuthorized, .libraryUnavailable: .destinationLevel(nil)
        case .networkError: .itemLevel
        case .assetNotFound, .resourceNotFound: .permanent(.resourceMissing)
        case .cancelled: .transient
        case .tokenExpired, .changeDetailsUnavailable: .verify
        case .other: .itemLevel
        }
    }

    public static func classify(_ error: SourceError) -> ErrorClass {
        switch error {
        case .unavailable: .destinationLevel(nil)
        case .fileMissing, .fileChanged: .permanent(.resourceMissing)
        case .cancelled: .transient
        case .readFailed: .itemLevel
        }
    }

    /// 403 reasons that are throttling, not a permission problem.
    private static let rateLimitReasons: Set<String> = [
        "dailyLimitExceeded", "sharingRateLimitExceeded", "rateLimitExceeded", "userRateLimitExceeded",
    ]

    /// HTTP status → destination error (Drive). 401 is passed in only after one refresh failed.
    public static func destinationError(httpStatus: Int, reason: String?, retryAfter: TimeInterval? = nil) -> DestinationError? {
        switch httpStatus {
        case 200..<300, 308: nil
        case 401: .unauthorized
        case 403 where reason == "storageQuotaExceeded" || reason == "quotaExceeded": .quotaExceeded
        case 403 where reason.map(rateLimitReasons.contains) == true: .rateLimited(retryAfter: retryAfter)
        case 404: .notFound
        case 409: .alreadyExists(remoteId: "")
        case 410: .sessionExpired
        case 429: .rateLimited(retryAfter: retryAfter)
        case 500..<600: .server(status: httpStatus)
        default: .itemRejected(reason: "http \(httpStatus)\(reason.map { " " + $0 } ?? "")")
        }
    }

    /// POSIX errno → destination error (local destinations).
    /// `atRoot` is true only when opening the destination root: there a permission error means the
    /// bookmark/grant is no longer valid. Below the root it only affects the one item.
    public static func destinationError(errno code: Int32, atRoot: Bool = false) -> DestinationError {
        switch code {
        case ENOSPC, EDQUOT: .noSpace
        case ENOENT: .notFound
        case EEXIST: .foreignFile
        case ENXIO, ENODEV, EIO, ETIMEDOUT, EHOSTDOWN, EHOSTUNREACH, ENETDOWN, ENETUNREACH, ESTALE: .offline
        case EACCES, EPERM: atRoot ? .bookmarkInvalid : .itemRejected(reason: "permission")
        case EROFS: .offline
        case EFBIG: .itemRejected(reason: permanentReasonPrefix + " file too large")
        case EILSEQ: .itemRejected(reason: permanentReasonPrefix + " invalid name")
        case ENAMETOOLONG: .itemRejected(reason: permanentReasonPrefix + " name too long")
        case EINTR, EAGAIN, EMFILE, ENFILE: .transient(reason: "errno \(code)")
        case ELOOP: .itemRejected(reason: "symlink")
        default: .itemRejected(reason: "errno \(code)")
        }
    }
}
