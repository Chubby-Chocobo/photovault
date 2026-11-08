import CryptoKit
import Foundation

/// Drive `appProperties` keys written by the app (FR-43, FR-01, spec 8.15).
public enum AppPropertyKey {
    public static let assetId = "pvAssetId"
    public static let resType = "pvResType"
    public static let kind = "pvKind"
    public static let category = "pvCategory"
    public static let schema = "pvSchema"
    public static let logical = "pvLogical"
    public static let view = "pvView"
    public static let root = "pvRoot"
    public static let archiveTimezone = "pvArchiveTZ"
}

/// The only string encoding for values that cross into Drive metadata, sidecars or local markers.
public enum AppPropertyCodec {
    public static let schemaVersion = "1"
    /// Drive limit for one appProperties key + value, in UTF-8 bytes [VERIFY M0-3].
    public static let maxPairBytes = 124

    public static func encode(_ type: ResourceType) -> String {
        switch type {
        case .photo: "photo"
        case .video: "video"
        case .audio: "audio"
        case .alternatePhoto: "alternatePhoto"
        case .fullSizePhoto: "fullSizePhoto"
        case .fullSizeVideo: "fullSizeVideo"
        case .adjustmentData: "adjustmentData"
        case .adjustmentBasePhoto: "adjustmentBasePhoto"
        case .pairedVideo: "pairedVideo"
        case .fullSizePairedVideo: "fullSizePairedVideo"
        case .adjustmentBasePairedVideo: "adjustmentBasePairedVideo"
        case .adjustmentBaseVideo: "adjustmentBaseVideo"
        case .photoProxy: "photoProxy"
        case .sidecarJson: "sidecarJson"
        case .sidecarXmp: "sidecarXmp"
        case .unknown(let raw): "unknown\(raw)"
        }
    }

    public static func decodeResourceType(_ string: String) -> ResourceType? {
        if string.hasPrefix("unknown"), let raw = Int(string.dropFirst(7)) { return .unknown(raw) }
        return knownTypes[string]
    }

    private static let knownTypes: [String: ResourceType] = {
        let all: [ResourceType] = [
            .photo, .video, .audio, .alternatePhoto, .fullSizePhoto, .fullSizeVideo, .adjustmentData,
            .adjustmentBasePhoto, .pairedVideo, .fullSizePairedVideo, .adjustmentBasePairedVideo,
            .adjustmentBaseVideo, .photoProxy, .sidecarJson, .sidecarXmp,
        ]
        return Dictionary(uniqueKeysWithValues: all.map { (encode($0), $0) })
    }()

    /// `pvLogical` value: the logical path when it fits, otherwise `h:` + 32 hex of its SHA-256.
    public static func logicalValue(_ logicalPath: String) -> String {
        if AppPropertyKey.logical.utf8.count + logicalPath.utf8.count <= maxPairBytes { return logicalPath }
        return "h:" + SHA256.hash(data: Data(logicalPath.utf8)).hexString.prefix(32)
    }

    /// Properties of an uploaded backup file.
    public static func fileProperties(assetKey: AssetKey, resType: ResourceType, category: AssetCategory) -> [String: String] {
        [
            AppPropertyKey.assetId: assetKey.appPropertyValue(),
            AppPropertyKey.resType: encode(resType),
            AppPropertyKey.kind: resType.kind.rawValue,
            AppPropertyKey.category: category.rawValue,
            AppPropertyKey.schema: schemaVersion,
        ]
    }

    /// Properties of an app-created folder (backup or view).
    public static func folderProperties(logicalPath: String, view: ViewKind?) -> [String: String] {
        var props = [AppPropertyKey.schema: schemaVersion, AppPropertyKey.logical: logicalValue(logicalPath)]
        if let view { props[AppPropertyKey.view] = view.rawValue }
        return props
    }

    /// Properties of a view shortcut.
    public static func shortcutProperties(assetKey: AssetKey, view: ViewKind, parentLogical: String) -> [String: String] {
        [
            AppPropertyKey.schema: schemaVersion,
            AppPropertyKey.view: view.rawValue,
            AppPropertyKey.assetId: assetKey.appPropertyValue(),
            AppPropertyKey.logical: logicalValue(parentLogical),
        ]
    }

    /// Properties of the backup root (FR-01 step 3, spec 8.15).
    public static func rootProperties(archiveTimezone: TimeZone) -> [String: String] {
        [
            AppPropertyKey.schema: schemaVersion,
            AppPropertyKey.root: "1",
            AppPropertyKey.archiveTimezone: archiveTimezone.identifier,
        ]
    }
}
