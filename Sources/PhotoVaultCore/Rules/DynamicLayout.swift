import Foundation

/// One folder level: logical path (never contains display names) and its display name.
public struct FolderLevel: Hashable, Sendable {
    public var logicalPath: String
    public var displayName: String

    public init(logicalPath: String, displayName: String) {
        self.logicalPath = logicalPath
        self.displayName = displayName
    }
}

/// Folder layout for backup files and views (spec §7 extension point).
public protocol LayoutPolicy: Sendable {
    /// Folders from the root down to the folder that holds the asset's files.
    func folderChain(for placement: Placement, placeName: String?) -> [FolderLevel]
    func viewFolderChain(_ path: ViewPath) -> [FolderLevel]
}

/// A view location; keys are stable, names are for display.
public enum ViewPath: Hashable, Sendable {
    case byDevice(groupKey: String, groupName: String, day: ArchiveDay)
    case byPlace(countryKey: String, countryName: String, areaKey: String, areaName: String, day: ArchiveDay)
    case favorites(day: ArchiveDay)
    case byLens(groupKey: String, lensName: String, day: ArchiveDay)

    public var view: ViewKind {
        switch self {
        case .byDevice: .byDevice
        case .byPlace: .byPlace
        case .favorites: .favorites
        case .byLens: .byLens
        }
    }
}

/// One folder per day (`YYYY-MM-DD`) under each branch: `Camera Uploads/` (day folders named with
/// their place when known), `Screenshots/`, `Saved/`; views end in the day.
public struct DynamicLayout: LayoutPolicy {
    public static let unknownDateName = "Unknown date"
    public static let cameraName = "Camera Uploads"
    public static let screenshotsName = "Screenshots"
    public static let savedName = "Saved"
    public static let byDeviceName = "By device"
    public static let byPlaceName = "By place"
    public static let favoritesName = "Favorites"
    public static let byLensName = "By lens"

    public init() {}

    public func folderChain(for placement: Placement, placeName: String?) -> [FolderLevel] {
        var levels: [FolderLevel] = []
        let branch = placement.category.rawValue
        switch placement.category {
        case .camera: levels.append(FolderLevel(logicalPath: branch, displayName: Self.cameraName))
        case .screenshot: levels.append(FolderLevel(logicalPath: branch, displayName: Self.screenshotsName))
        case .saved: levels.append(FolderLevel(logicalPath: branch, displayName: Self.savedName))
        }
        switch placement.day {
        case .unknown:
            levels.append(FolderLevel(logicalPath: "\(branch)/unknown", displayName: Self.unknownDateName))
        case .day(let day):
            let name = placement.category == .camera ? Self.dayFolderName(day, placeName: placeName) : day.description
            levels.append(FolderLevel(logicalPath: "\(branch)/\(day.description)", displayName: name))
        }
        return levels
    }

    /// `YYYY-MM-DD[ <place>]`, sanitized.
    public static func dayFolderName(_ day: ArchiveDay, placeName: String?) -> String {
        guard let placeName, !placeName.isEmpty else { return day.description }
        return NameSanitizer.sanitize("\(day.description) \(placeName)")
    }

    public func viewFolderChain(_ path: ViewPath) -> [FolderLevel] {
        switch path {
        case let .byDevice(groupKey, groupName, day):
            let root = "view/byDevice"
            let group = "\(root)/\(groupKey)"
            return [
                FolderLevel(logicalPath: root, displayName: Self.byDeviceName),
                FolderLevel(logicalPath: group, displayName: NameSanitizer.sanitize(groupName)),
                FolderLevel(logicalPath: "\(group)/\(day.description)", displayName: day.description),
            ]
        case let .byPlace(countryKey, countryName, areaKey, areaName, day):
            let root = "view/byPlace"
            let country = "\(root)/\(countryKey)"
            let area = "\(country)/\(areaKey)"
            return [
                FolderLevel(logicalPath: root, displayName: Self.byPlaceName),
                FolderLevel(logicalPath: country, displayName: NameSanitizer.sanitize(countryName)),
                FolderLevel(logicalPath: area, displayName: NameSanitizer.sanitize(areaName)),
                FolderLevel(logicalPath: "\(area)/\(day.description)", displayName: day.description),
            ]
        case let .byLens(groupKey, lensName, day):
            let root = "view/byLens"
            let group = "\(root)/\(groupKey)"
            return [
                FolderLevel(logicalPath: root, displayName: Self.byLensName),
                FolderLevel(logicalPath: group, displayName: NameSanitizer.sanitize(lensName)),
                FolderLevel(logicalPath: "\(group)/\(day.description)", displayName: day.description),
            ]
        case let .favorites(day):
            let root = "view/favorites"
            return [
                FolderLevel(logicalPath: root, displayName: Self.favoritesName),
                FolderLevel(logicalPath: "\(root)/\(day.description)", displayName: day.description),
            ]
        }
    }
}
