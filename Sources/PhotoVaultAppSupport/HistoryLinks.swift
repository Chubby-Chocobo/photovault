import Foundation

/// Where "Open on Drive" and "Show in Finder" go for a backed-up file.
public enum HistoryLinks {
    /// The Drive page of a file id; nil unless the id is made of Drive id characters.
    public static func driveFile(remoteId: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard !remoteId.isEmpty, remoteId.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return URL(string: "https://drive.google.com/file/d/\(remoteId)/view")
    }

    /// A file under a folder destination's root: `relativePath` as the job stores it ("Camera Uploads/2026-11-10/x.HEIC").
    /// Nil for an absolute path or one with an empty, `.` or `..` part, so nothing outside the root is ever revealed.
    public static func localFile(root: URL, relativePath: String) -> URL? {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relativePath.hasPrefix("/"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { return nil }
        return parts.reduce(root) { $0.appendingPathComponent($1, isDirectory: false) }
    }
}
