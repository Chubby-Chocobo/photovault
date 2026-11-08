import Foundation
import PhotoVaultCore

/// Where a destination root stands on disk: inside a Trash, deleted, or on a volume that is gone.
enum RootState {
    /// True when `url` is inside `~/.Trash`, `/Volumes/*/.Trashes` or the Trash FileManager reports for its volume.
    static func isInTrash(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if url.standardizedFileURL.pathComponents.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) { return true }
        if let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false) {
            let prefix = trash.standardizedFileURL.path
            if path == prefix || path.hasPrefix(prefix + "/") { return true }
        }
        return false
    }

    /// `offline` when the path lies on a `/Volumes/<name>` that is not mounted (or the path is unknown);
    /// `rootMissing` when the volume is there but the folder is gone.
    static func missingError(path: String?) -> DestinationError {
        guard let path else { return .offline }
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        if parts.count >= 3, parts[1] == "Volumes" {
            let mountPoint = "/Volumes/" + parts[2]
            return FileManager.default.fileExists(atPath: mountPoint) ? .rootMissing : .offline
        }
        return .rootMissing
    }
}
