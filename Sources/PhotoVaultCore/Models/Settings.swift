import Foundation

/// Global settings with the FR-05 defaults. Content switches are a ceiling for every destination.
public struct GlobalSettings: Hashable, Codable, Sendable {
    public var includeVideos = true
    public var includeEdited = true
    public var includeAllBurstFrames = true
    public var includeHidden = false
    /// Backfill and re-export rate (FR-05, 8.5).
    public var backfillBytesPerHour: Int64 = 20 * GiB
    public var backfillOnlyOnACPower = true
    public var allUploadsOnlyOnACPower = false
    public var pauseOnExpensiveNetwork = true
    public var lowWatermarkBytes: Int64 = 15 * GiB
    public var criticalWatermarkBytes: Int64 = 5 * GiB
    public var stagingSoftLimitBytes: Int64 = 4 * GiB
    /// Off until the owner turns it on: registering a login item needs their consent.
    public var launchAtLogin = false
    public var chatAppAlbumNames: [String] = GlobalSettings.defaultChatAppAlbums
    public var photosWithoutCameraExifAreSaved = true
    public var placeNamesEnabled = true
    public var homeCountryCode = "VN"
    public var sidecarJsonEnabled = true
    public var sidecarXmpEnabled = true
    public var viewByDeviceEnabled = true
    public var viewByPlaceEnabled = true
    public var viewFavoritesEnabled = true
    /// Off by default: turning it on adds one shortcut per photo that has a lens.
    public var viewByLensEnabled = false
    public var integrityCheckIntervalDays = 7

    public init() {}

    public static let GiB: Int64 = 1 << 30

    public static let defaultChatAppAlbums = [
        "WhatsApp", "Zalo", "Messenger", "Telegram", "Viber", "LINE", "Signal",
        "Instagram", "Facebook", "Threads", "X", "TikTok",
    ]
}

/// Per-destination content rules (FR-72). Combined with `GlobalSettings` by AND.
public struct DestinationRules: Hashable, Codable, Sendable {
    public var categories: Set<AssetCategory> = Set(AssetCategory.allCases)
    /// Photos, including the paired video of a Live Photo.
    public var includePhotos = true
    public var includeVideos = true
    public var includeRaw = true
    public var includeOriginals = true
    public var includeEdited = true
    public var sidecarJson = true
    public var sidecarXmp = true
    /// Skip any single file larger than this (FR-33); nil = no limit.
    public var skipLargerThanBytes: Int64?

    public init() {}

    public static let everything = DestinationRules()
}
