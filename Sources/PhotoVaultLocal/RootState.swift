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
    /// The bookmark's volume UUID identifies the volume; shares without one (SMB) are told apart by the
    /// URL the system would remount them from. With neither, only the mount point's presence under
    /// `/Volumes` can tell.
    static func missingError(path: String?, bookmarkVolumeUUID: String? = nil, bookmarkRemountURL: String? = nil,
                             volumes: any VolumeLookup = SystemVolumeLookup()) -> DestinationError {
        guard let path else { return .offline }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let bookmarkVolumeUUID {
            return volumes.mountedVolume(containing: standardized).uuid == bookmarkVolumeUUID ? .rootMissing : .offline
        }
        if let bookmarkRemountURL {
            let mounted = volumes.mountedVolume(containing: standardized).remountURL.flatMap(shareIdentity)
            return mounted != nil && mounted == shareIdentity(bookmarkRemountURL) ? .rootMissing : .offline
        }
        let parts = URL(fileURLWithPath: standardized).pathComponents
        guard parts.count >= 3, parts[1] == "Volumes" else { return .rootMissing }
        return FileManager.default.fileExists(atPath: "/Volumes/" + parts[2]) ? .rootMissing : .offline
    }

    /// Scheme, host and share path of a remount URL, without the user name or password and with the
    /// host lower-cased: the same share mounted by another user is the same volume.
    static func shareIdentity(_ remountURL: String) -> String? {
        guard let components = URLComponents(string: remountURL), let host = components.host, !host.isEmpty else { return nil }
        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return "\((components.scheme ?? "").lowercased())://\(host.lowercased())\(path)"
    }
}

/// What identifies a mounted volume: a UUID when the filesystem has one, else the URL it remounts from.
struct MountedVolume: Equatable, Sendable {
    var uuid: String?
    var remountURL: String?
}

/// Which volume is mounted at a path now; a seam so tests can stage two volumes with the same name.
protocol VolumeLookup: Sendable {
    /// The volume holding `path`, or its nearest existing ancestor; empty when unknown.
    func mountedVolume(containing path: String) -> MountedVolume
}

struct SystemVolumeLookup: VolumeLookup {
    func mountedVolume(containing path: String) -> MountedVolume {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLForRemountingKey])
        return MountedVolume(uuid: values?.volumeUUIDString, remountURL: values?.volumeURLForRemounting?.absoluteString)
    }
}
