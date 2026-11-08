import Foundation

/// Row of the `asset` table (spec 8.2).
public struct AssetRecord: Hashable, Codable, Sendable {
    public var assetKey: AssetKey
    public var localId: String
    public var cloudId: String?
    public var creationDate: Date?
    public var modificationDate: Date?
    public var mediaType: MediaType
    public var mediaSubtypes: MediaSubtypes
    public var category: AssetCategory?
    public var categoryReason: CategoryReason?
    public var categoryProvisional: Bool
    /// Fixed once (spec 8.1); nil until placed.
    public var placement: Placement?
    public var placedAt: Date?
    public var isHidden: Bool
    public var isFavorite: Bool
    public var burstIdentifier: String?
    /// The burst's representative or a user/auto pick; used when "every burst frame" is off.
    public var burstIsPick: Bool
    public var location: GeoPoint?
    public var geoCell: GeoCell?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var duration: Double
    public var cameraMake: String?
    public var cameraModel: String?
    public var lensModel: String?
    public var hasAdjustments: Bool
    public var adjustmentHash: String?
    public var editCheckPending: Bool
    /// NULL = present at the Drive baseline; otherwise when the asset entered the library (8.8).
    public var insertedAt: Date?
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var deletedAt: Date?

    public init(
        assetKey: AssetKey, localId: String, cloudId: String? = nil, creationDate: Date? = nil,
        modificationDate: Date? = nil, mediaType: MediaType, mediaSubtypes: MediaSubtypes = [],
        category: AssetCategory? = nil, categoryReason: CategoryReason? = nil, categoryProvisional: Bool = false,
        placement: Placement? = nil, placedAt: Date? = nil, isHidden: Bool = false, isFavorite: Bool = false,
        burstIdentifier: String? = nil, burstIsPick: Bool = true, location: GeoPoint? = nil, geoCell: GeoCell? = nil,
        pixelWidth: Int = 0, pixelHeight: Int = 0, duration: Double = 0, cameraMake: String? = nil,
        cameraModel: String? = nil, lensModel: String? = nil, hasAdjustments: Bool = false,
        adjustmentHash: String? = nil, editCheckPending: Bool = false, insertedAt: Date? = nil,
        firstSeenAt: Date, lastSeenAt: Date, deletedAt: Date? = nil
    ) {
        self.assetKey = assetKey
        self.localId = localId
        self.cloudId = cloudId
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.mediaType = mediaType
        self.mediaSubtypes = mediaSubtypes
        self.category = category
        self.categoryReason = categoryReason
        self.categoryProvisional = categoryProvisional
        self.placement = placement
        self.placedAt = placedAt
        self.isHidden = isHidden
        self.isFavorite = isFavorite
        self.burstIdentifier = burstIdentifier
        self.burstIsPick = burstIsPick
        self.location = location
        self.geoCell = geoCell
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.hasAdjustments = hasAdjustments
        self.adjustmentHash = adjustmentHash
        self.editCheckPending = editCheckPending
        self.insertedAt = insertedAt
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.deletedAt = deletedAt
    }

    /// Archive day used for `since` scope and day folders: the placement day once placed,
    /// otherwise the creation date in `timeZone`.
    public func archiveDay(in timeZone: TimeZone) -> ArchiveDay? {
        if let placement { return placement.day.archiveDay }
        return creationDate.map { ArchiveDay(date: $0, timeZone: timeZone) }
    }
}

/// Row of `asset_alias`: an identifier seen later for an existing asset (8.1).
public struct AssetAlias: Hashable, Codable, Sendable {
    public var alias: String
    public var assetKey: AssetKey

    public init(alias: String, assetKey: AssetKey) {
        self.alias = alias
        self.assetKey = assetKey
    }
}

/// Row of `album_member`.
public struct AlbumMember: Hashable, Codable, Sendable {
    public var albumLocalId: String
    public var albumTitle: String
    public var assetKey: AssetKey

    public init(albumLocalId: String, albumTitle: String, assetKey: AssetKey) {
        self.albumLocalId = albumLocalId
        self.albumTitle = albumTitle
        self.assetKey = assetKey
    }
}
