import CryptoKit
import Foundation

/// One file of the asset at the destination the sidecar is written for (FR-91 `resources`).
public struct SidecarResource: Hashable, Sendable {
    public var type: ResourceType
    public var kind: ResourceKind
    public var originalName: String
    public var backupName: String
    public var size: Int64?
    public var md5: String?
    public var sha256: String?
    public var state: JobState

    public init(
        type: ResourceType, kind: ResourceKind, originalName: String, backupName: String, size: Int64? = nil,
        md5: String? = nil, sha256: String? = nil, state: JobState
    ) {
        self.type = type
        self.kind = kind
        self.originalName = originalName
        self.backupName = backupName
        self.size = size
        self.md5 = md5
        self.sha256 = sha256
        self.state = state
    }
}

/// Caption and keywords from `PHAssetExtendedMetadata` (macOS 27+, [VERIFY]).
public struct SidecarExtendedMetadata: Hashable, Sendable {
    public var caption: String?
    public var keywords: [String]

    public init(caption: String? = nil, keywords: [String] = []) {
        self.caption = caption
        self.keywords = keywords
    }
}

/// Where an imported asset came from. Present only for assets that do not come from Photos.
public struct SidecarSource: Hashable, Sendable {
    public var kind: String
    /// Name of the import (the folder's name).
    public var name: String
    /// Path of the primary file inside the import.
    public var path: String
    public var dateSource: DateSource?

    public init(kind: String, name: String, path: String, dateSource: DateSource? = nil) {
        self.kind = kind
        self.name = name
        self.path = path
        self.dateSource = dateSource
    }
}

/// Everything a sidecar depends on. The same input always yields the same bytes.
public struct SidecarInput: Sendable {
    public static let currentSchemaVersion = 1

    public var asset: AssetRecord
    public var albumTitles: [String]
    /// Names of the asset's cell under `PlaceNameRule` (no native name in parentheses), when geocoded.
    public var place: GeoPlace?
    public var deviceDisplayName: String?
    /// Resources of this destination only.
    public var resources: [SidecarResource]
    public var archiveTimeZone: TimeZone
    /// nil when the SDK has no extended metadata; JSON then says `"extendedMetadata":"unavailable"`.
    public var extendedMetadata: SidecarExtendedMetadata?
    public var schemaVersion: Int
    /// nil for Photos assets, whose sidecars carry no `source` block.
    public var source: SidecarSource?

    public init(
        asset: AssetRecord, albumTitles: [String], place: GeoPlace?, deviceDisplayName: String?,
        resources: [SidecarResource], archiveTimeZone: TimeZone, extendedMetadata: SidecarExtendedMetadata? = nil,
        schemaVersion: Int = SidecarInput.currentSchemaVersion, source: SidecarSource? = nil
    ) {
        self.asset = asset
        self.albumTitles = albumTitles
        self.place = place
        self.deviceDisplayName = deviceDisplayName
        self.resources = resources
        self.archiveTimeZone = archiveTimeZone
        self.extendedMetadata = extendedMetadata
        self.schemaVersion = schemaVersion
        self.source = source
    }
}

/// Generated file content with the hashes stored as the job's uploaded hash.
public struct SidecarFile: Hashable, Sendable {
    public let data: Data
    public let sha256: String
    public let md5: String

    public init(data: Data) {
        self.data = data
        self.sha256 = SHA256.hash(data: data).hexString
        self.md5 = Insecure.MD5.hash(data: data).hexString
    }
}
