import Foundation

/// `photos` or `folder-<uuid>`: where an asset came from.
public struct SourceID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        if rawValue == "photos" {
            self.rawValue = rawValue
        } else if rawValue.hasPrefix("folder-"), let uuid = UUID(uuidString: String(rawValue.dropFirst(7))),
                  rawValue == "folder-" + uuid.uuidString.lowercased() {
            self.rawValue = rawValue
        } else {
            return nil
        }
    }

    public static let photos = SourceID(rawValue: "photos")!

    public static func folder(_ uuid: UUID = UUID()) -> SourceID {
        SourceID(rawValue: "folder-" + uuid.uuidString.lowercased())!
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let id = SourceID(rawValue: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid source id"))
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
    public static func < (lhs: SourceID, rhs: SourceID) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum SourceKind: String, Codable, Sendable, CaseIterable {
    case photos
    case localFolder
    /// Files and folders picked in Google Drive (desktop Picker, `drive.file`).
    case googleDrive
    /// A folder in Dropbox, or the whole account.
    case dropbox

    /// One-time import kinds: everything except Photos.
    public var isImport: Bool { self != .photos }
}

/// Keychain account names of cloud import grants, shared by the adapters and the app.
public enum CloudTokenAccount {
    /// The Dropbox account the owner browses with; each import keeps its own copy.
    public static let dropbox = "dropbox-account"

    /// The grant one cloud import reads with.
    public static func importGrant(_ id: SourceID) -> String { "import-\(id.rawValue)" }
}

public enum SourceMode: String, Codable, Sendable, CaseIterable {
    case continuous
    case oneTime
}

public enum SourceStatus: String, Codable, Sendable, CaseIterable {
    case scanning, importing, offline, completed, cancelled

    /// Still has work to do or is waiting for its folder.
    public var isOpen: Bool { self == .scanning || self == .importing || self == .offline }
}

/// Where a file's date came from (sidecar `source.dateSource`).
public enum DateSource: String, Codable, Sendable, CaseIterable {
    case exif, video, fileDate
}

/// `localId` of an imported asset: `<sourceId>/<relative path of the primary file, NFC>`.
public struct ImportLocator: Hashable, Sendable {
    public var sourceId: SourceID
    public var relativePath: String

    public init(sourceId: SourceID, relativePath: String) {
        self.sourceId = sourceId
        self.relativePath = relativePath.precomposedStringWithCanonicalMapping
    }

    public init?(localId: String) {
        guard let slash = localId.firstIndex(of: "/"),
              let id = SourceID(rawValue: String(localId[..<slash])), id != .photos else { return nil }
        let path = String(localId[localId.index(after: slash)...])
        guard !path.isEmpty else { return nil }
        self.init(sourceId: id, relativePath: path)
    }

    public var localId: String { sourceId.rawValue + "/" + relativePath }

    /// Directory part of the relative path ("" for the root).
    public var directory: String {
        guard let slash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[..<slash])
    }

    /// Relative path of another file in the primary's directory (every file of a group shares it).
    public func sibling(named filename: String) -> String {
        let name = filename.precomposedStringWithCanonicalMapping
        return directory.isEmpty ? name : directory + "/" + name
    }
}
