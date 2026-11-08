import Foundation

/// The only error type destinations throw. `ErrorClassifier` maps it to the 8.14 classes.
public enum DestinationError: Error, Hashable, Sendable, CustomStringConvertible {
    /// HTTP 401 that survived one token refresh.
    case unauthorized
    /// Refresh token rejected (`invalid_grant`) or missing from the Keychain.
    case reauthRequired
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int)
    case offline
    case noSpace
    case quotaExceeded
    case dailyCapReached
    case bookmarkInvalid
    case folderMissing(logicalPath: String)
    case folderTrashed(logicalPath: String)
    case rootMissing
    case rootTrashed
    /// A create used an ID that already exists; the caller must verify with a probe (FR-47).
    case alreadyExists(remoteId: String)
    /// Resumable session expired or unknown.
    case sessionExpired
    case notFound
    case checksumMismatch(expected: String, actual: String)
    /// A file the app did not write occupies the target path.
    case foreignFile
    /// A file the app wrote was modified by someone else.
    case foreignModified
    /// Shortcut operations are not permitted with the current scope (FR-103).
    case viewsNotPermitted
    case itemRejected(reason: String)
    case transient(reason: String)

    public var description: String {
        switch self {
        case .unauthorized: "unauthorized"
        case .reauthRequired: "reauthRequired"
        case .rateLimited: "rateLimited"
        case .server(let s): "server(\(s))"
        case .offline: "offline"
        case .noSpace: "noSpace"
        case .quotaExceeded: "quotaExceeded"
        case .dailyCapReached: "dailyCapReached"
        case .bookmarkInvalid: "bookmarkInvalid"
        case .folderMissing: "folderMissing"
        case .folderTrashed: "folderTrashed"
        case .rootMissing: "rootMissing"
        case .rootTrashed: "rootTrashed"
        case .alreadyExists: "alreadyExists"
        case .sessionExpired: "sessionExpired"
        case .notFound: "notFound"
        case .checksumMismatch: "checksumMismatch"
        case .foreignFile: "foreignFile"
        case .foreignModified: "foreignModified"
        case .viewsNotPermitted: "viewsNotPermitted"
        case .itemRejected(let r): "itemRejected(\(r))"
        case .transient(let r): "transient(\(r))"
        }
    }
}

/// Errors from the Photos source.
public enum PhotosSourceError: Error, Hashable, Sendable {
    /// The change token is older than the available history (PHPhotosError 3105).
    case tokenExpired
    /// Change details are unavailable (PHPhotosError 3210); reconcile.
    case changeDetailsUnavailable
    case notAuthorized
    case assetNotFound(localId: String)
    case resourceNotFound(localId: String, type: ResourceType)
    /// Network access to iCloud failed; retryable item error.
    case networkError
    /// Export cancelled by the caller (disk guard or size rule).
    case cancelled
    case libraryUnavailable
    case other(code: Int, domain: String)
}
