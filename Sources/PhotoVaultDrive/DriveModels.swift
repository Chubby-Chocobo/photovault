import Foundation
import PhotoVaultCore

enum DriveMime {
    static let folder = "application/vnd.google-apps.folder"
    static let shortcut = "application/vnd.google-apps.shortcut"
}

/// Response shape; requested through `DriveAPI.fileFields`.
struct DriveFile: Decodable, Equatable {
    struct ShortcutDetails: Codable, Equatable { var targetId: String? }
    var id: String
    var name: String?
    var mimeType: String?
    var md5Checksum: String?
    var trashed: Bool?
    var parents: [String]?
    var size: String?
    var appProperties: [String: String]?
    var shortcutDetails: ShortcutDetails?
    var description: String?

    var isFolder: Bool { mimeType == DriveMime.folder }
    var isShortcut: Bool { mimeType == DriveMime.shortcut }

    var remoteItem: RemoteItem {
        RemoteItem(remoteId: id, name: name ?? "", parentIds: parents ?? [],
                   kind: isFolder ? .folder : isShortcut ? .shortcut : .file,
                   size: size.flatMap { Int64($0) }, md5: md5Checksum, appProperties: appProperties ?? [:],
                   shortcutTargetId: shortcutDetails?.targetId, trashed: trashed ?? false)
    }
}

/// Request body for create/update metadata. Nil fields are omitted.
struct DriveFileWrite: Encodable {
    var id: String?
    var name: String?
    var mimeType: String?
    var parents: [String]?
    var appProperties: [String: String]?
    var description: String?
    var shortcutDetails: DriveFile.ShortcutDetails?
    var trashed: Bool?
}

struct DriveFilePage {
    var files: [DriveFile]
    var nextPageToken: String?
}
