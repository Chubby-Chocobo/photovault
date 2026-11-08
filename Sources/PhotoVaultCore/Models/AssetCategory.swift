import Foundation

/// Archive branch an asset is filed under (spec §3, FR-20).
public enum AssetCategory: String, Codable, Sendable, CaseIterable, Comparable {
    case camera
    case screenshot
    case saved

    public static func < (lhs: AssetCategory, rhs: AssetCategory) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Which FR-20 rule produced the category.
public enum CategoryReason: String, Codable, Sendable, CaseIterable {
    /// Rule 1: screenshot or screen recording subtype.
    case screenshotSubtype
    /// Rule 2: member of a user album named exactly like a chat app.
    case chatAppAlbum
    /// Rule 3: photo without TIFF Make and Model and without a RAW resource.
    case missingCameraExif
    /// Rule 4 for videos, assets with RAW, and photos whose header proved camera EXIF.
    case cameraDefault
    /// Provisional `camera` until the header has been read.
    case pendingHeaderRead
}
