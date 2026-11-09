import Foundation

/// WGS84 coordinate.
public struct GeoPoint: Hashable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Grid cell of about 0.01° (~1 km) used for geocoding and caching (FR-84). Only cell centres are
/// ever sent to a geocoder (FR-85).
public struct GeoCell: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public static let size = 0.01
    public let latIndex: Int
    public let lonIndex: Int

    public init(latIndex: Int, lonIndex: Int) {
        self.latIndex = latIndex
        self.lonIndex = lonIndex
    }

    public init(_ point: GeoPoint) {
        latIndex = Int((point.latitude / Self.size).rounded(.down))
        lonIndex = Int((point.longitude / Self.size).rounded(.down))
    }

    /// Parses the `"<lat>:<lon>"` storage key.
    public init?(key: String) {
        let parts = key.split(separator: ":")
        guard parts.count == 2, let la = Int(parts[0]), let lo = Int(parts[1]) else { return nil }
        self.init(latIndex: la, lonIndex: lo)
    }

    public var key: String { "\(latIndex):\(lonIndex)" }

    public var center: GeoPoint {
        GeoPoint(latitude: (Double(latIndex) + 0.5) * Self.size, longitude: (Double(lonIndex) + 0.5) * Self.size)
    }

    public var description: String { key }
    public static func < (lhs: GeoCell, rhs: GeoCell) -> Bool { (lhs.latIndex, lhs.lonIndex) < (rhs.latIndex, rhs.lonIndex) }
}

/// One resource as reported by the Photos source (`PHAssetResource`).
public struct ResourceDescriptor: Hashable, Codable, Sendable {
    public var type: ResourceType
    public var uti: String
    public var originalFilename: String
    /// UTI conforms to `public.camera-raw-image` (FR-21: RAW by UTI, not by resource type).
    public var isRaw: Bool

    public init(type: ResourceType, uti: String, originalFilename: String, isRaw: Bool) {
        self.type = type
        self.uti = uti
        self.originalFilename = originalFilename
        self.isRaw = isRaw
    }
}

/// What the Photos source reports for one asset. No resource data.
public struct AssetSnapshot: Hashable, Codable, Sendable {
    public var localId: String
    public var cloudId: String?
    public var mediaType: MediaType
    public var subtypes: MediaSubtypes
    public var creationDate: Date?
    public var modificationDate: Date?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var duration: Double
    public var isFavorite: Bool
    public var isHidden: Bool
    public var burstIdentifier: String?
    /// The burst's representative or a user/auto pick; used when "every burst frame" is off.
    public var burstIsPick: Bool
    public var location: GeoPoint?
    public var hasAdjustments: Bool
    public var resources: [ResourceDescriptor]

    public init(
        localId: String, cloudId: String? = nil, mediaType: MediaType, subtypes: MediaSubtypes = [],
        creationDate: Date?, modificationDate: Date? = nil, pixelWidth: Int = 0, pixelHeight: Int = 0,
        duration: Double = 0, isFavorite: Bool = false, isHidden: Bool = false, burstIdentifier: String? = nil, burstIsPick: Bool = true,
        location: GeoPoint? = nil, hasAdjustments: Bool = false, resources: [ResourceDescriptor]
    ) {
        self.localId = localId
        self.cloudId = cloudId
        self.mediaType = mediaType
        self.subtypes = subtypes
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.burstIdentifier = burstIdentifier
        self.burstIsPick = burstIsPick
        self.location = location
        self.hasAdjustments = hasAdjustments
        self.resources = resources
    }

    public var hasRaw: Bool { resources.contains(where: \.isRaw) }
}

/// A user album (FR-20 rule 2, `album_member`).
public struct AlbumSnapshot: Hashable, Codable, Sendable {
    public var localId: String
    public var title: String
    public var assetLocalIds: [String]

    public init(localId: String, title: String, assetLocalIds: [String]) {
        self.localId = localId
        self.title = title
        self.assetLocalIds = assetLocalIds
    }
}

/// Capture metadata read from the primary resource (FR-34). Missing values are nil, never errors.
public struct CaptureMetadata: Hashable, Codable, Sendable {
    public var make: String?
    public var model: String?
    public var lensModel: String?
    public var dateTimeOriginal: String?
    public var offsetTime: String?

    public init(make: String? = nil, model: String? = nil, lensModel: String? = nil,
                dateTimeOriginal: String? = nil, offsetTime: String? = nil) {
        self.make = make
        self.model = model
        self.lensModel = lensModel
        self.dateTimeOriginal = dateTimeOriginal
        self.offsetTime = offsetTime
    }

    /// FR-20 rule 3 input: true when either TIFF Make or Model is present.
    public var hasCameraIdentity: Bool {
        !(make?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            || !(model?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }

    public static let empty = CaptureMetadata()
}
