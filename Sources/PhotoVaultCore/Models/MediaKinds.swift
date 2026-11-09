import Foundation

/// Mirrors `PHAssetMediaType` raw values.
public enum MediaType: Int, Codable, Sendable, CaseIterable {
    case unknown = 0
    case image = 1
    case video = 2
    case audio = 3
}

/// Mirrors `PHAssetMediaSubtype` bit values (SDK `PhotosTypes.h`).
public struct MediaSubtypes: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let photoPanorama = MediaSubtypes(rawValue: 1 << 0)
    public static let photoHDR = MediaSubtypes(rawValue: 1 << 1)
    public static let photoScreenshot = MediaSubtypes(rawValue: 1 << 2)
    public static let photoLive = MediaSubtypes(rawValue: 1 << 3)
    public static let photoDepthEffect = MediaSubtypes(rawValue: 1 << 4)
    public static let spatialMedia = MediaSubtypes(rawValue: 1 << 10)
    public static let videoStreamed = MediaSubtypes(rawValue: 1 << 16)
    public static let videoHighFrameRate = MediaSubtypes(rawValue: 1 << 17)
    public static let videoTimelapse = MediaSubtypes(rawValue: 1 << 18)
    public static let videoScreenRecording = MediaSubtypes(rawValue: 1 << 19)
    public static let videoCinematic = MediaSubtypes(rawValue: 1 << 21)
}

/// Resource type. Raw values below 1000 mirror `PHAssetResourceType`; sidecars use 1001/1002.
public enum ResourceType: RawRepresentable, Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    case photo, video, audio, alternatePhoto, fullSizePhoto, fullSizeVideo, adjustmentData
    case adjustmentBasePhoto, pairedVideo, fullSizePairedVideo, adjustmentBasePairedVideo
    case adjustmentBaseVideo, photoProxy
    case sidecarJson, sidecarXmp
    case unknown(Int)

    public init(rawValue: Int) {
        switch rawValue {
        case 1: self = .photo
        case 2: self = .video
        case 3: self = .audio
        case 4: self = .alternatePhoto
        case 5: self = .fullSizePhoto
        case 6: self = .fullSizeVideo
        case 7: self = .adjustmentData
        case 8: self = .adjustmentBasePhoto
        case 9: self = .pairedVideo
        case 10: self = .fullSizePairedVideo
        case 11: self = .adjustmentBasePairedVideo
        case 12: self = .adjustmentBaseVideo
        case 19: self = .photoProxy
        case 1001: self = .sidecarJson
        case 1002: self = .sidecarXmp
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: Int {
        switch self {
        case .photo: 1
        case .video: 2
        case .audio: 3
        case .alternatePhoto: 4
        case .fullSizePhoto: 5
        case .fullSizeVideo: 6
        case .adjustmentData: 7
        case .adjustmentBasePhoto: 8
        case .pairedVideo: 9
        case .fullSizePairedVideo: 10
        case .adjustmentBasePairedVideo: 11
        case .adjustmentBaseVideo: 12
        case .photoProxy: 19
        case .sidecarJson: 1001
        case .sidecarXmp: 1002
        case .unknown(let value): value
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(Int.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Edited renditions (FR-21).
    public var isEdited: Bool { [.fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo].contains(self) }
    public var isSidecar: Bool { self == .sidecarJson || self == .sidecarXmp }

    public var kind: ResourceKind {
        switch self {
        case .sidecarJson: .sidecarJson
        case .sidecarXmp: .sidecarXmp
        case _ where isEdited: .edited
        default: .original
        }
    }

    public var description: String { AppPropertyCodec.encode(self) }

    public static func < (lhs: ResourceType, rhs: ResourceType) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What a file at a destination represents.
public enum ResourceKind: String, Codable, Sendable, CaseIterable {
    case original
    case edited
    case sidecarJson
    case sidecarXmp
}
