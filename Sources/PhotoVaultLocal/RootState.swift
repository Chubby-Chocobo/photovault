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

    /// `offline` when the volume the root lived on is not the one mounted at its path now (or the path is
    /// unknown); `rootMissing` when that same volume is mounted but the folder is gone.
    /// `bookmarkVolumeUUID` is the volume UUID stored in the bookmark; without one only the mount point's
    /// presence under `/Volumes` can tell.
    static func missingError(path: String?, bookmarkVolumeUUID: String? = nil,
                             volumes: any VolumeLookup = SystemVolumeLookup()) -> DestinationError {
        guard let path else { return .offline }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let bookmarkVolumeUUID else {
            let parts = URL(fileURLWithPath: standardized).pathComponents
            guard parts.count >= 3, parts[1] == "Volumes" else { return .rootMissing }
            return FileManager.default.fileExists(atPath: "/Volumes/" + parts[2]) ? .rootMissing : .offline
        }
        return volumes.mountedVolumeUUID(containing: standardized) == bookmarkVolumeUUID ? .rootMissing : .offline
    }
}

/// Which volume is mounted at a path now; a seam so tests can stage two volumes with the same name.
protocol VolumeLookup: Sendable {
    /// UUID of the volume holding `path`, or of its nearest existing ancestor; nil when unknown.
    func mountedVolumeUUID(containing path: String) -> String?
}

struct SystemVolumeLookup: VolumeLookup {
    func mountedVolumeUUID(containing path: String) -> String? {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        return try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }
}
