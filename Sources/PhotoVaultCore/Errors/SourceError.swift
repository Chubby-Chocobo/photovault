import Foundation

/// Errors from content sources other than Photos. Carries no paths or file names.
public enum SourceError: Error, Hashable, Sendable {
    /// The source cannot be reached (disk unplugged, bookmark invalid, folder gone).
    case unavailable
    /// The file is gone from the source.
    case fileMissing
    /// The file no longer has the bytes it had when it was imported.
    case fileChanged
    /// The provider no longer accepts the stored grant (revoked, expired refresh token): the owner must sign in again.
    case accessRevoked
    /// The provider is throttling or briefly failing (rate limit, 5xx). Nothing is wrong with the file or the grant:
    /// the read is tried again a little later.
    case busy
    case cancelled
    case readFailed(code: Int)
}
