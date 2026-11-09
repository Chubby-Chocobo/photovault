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
    func folderChain(for placement: Placement, dayPromoted: Bool, placeName: String?) -> [FolderLevel]
    func viewFolderChain(_ path: ViewPath) -> [FolderLevel]
}

/// A view location; keys are stable, names are for display.
public enum ViewPath: Hashable, Sendable {
    case byDevice(groupKey: String, groupName: String, day: ArchiveDay)
    case byPlace(countryKey: String, countryName: String, areaKey: String, areaName: String, day: ArchiveDay)
    case favorites(day: ArchiveDay)

    public var view: ViewKind {
        switch self {
        case .byDevice: .byDevice
        case .byPlace: .byPlace
        case .favorites: .favorites
        }
    }
}

/// `Năm/Tháng` with promoted day folders (FR-40, 8.7).
public struct DynamicLayout: LayoutPolicy {
    public static let unknownDateName = "Unknown date"
    public static let screenshotsName = "Screenshots"
    public static let savedName = "Saved"
    public static let byDeviceName = "By device"
    public static let byPlaceName = "By place"
    public static let favoritesName = "Favorites"

    public init() {}

    public func folderChain(for placement: Placement, dayPromoted: Bool, placeName: String?) -> [FolderLevel] {
        var levels: [FolderLevel] = []
        let branch = placement.category.rawValue
        switch placement.category {
        case .camera: break
        case .screenshot: levels.append(FolderLevel(logicalPath: branch, displayName: Self.screenshotsName))
        case .saved: levels.append(FolderLevel(logicalPath: branch, displayName: Self.savedName))
        }
        switch placement.day {
        case .unknown:
            levels.append(FolderLevel(logicalPath: "\(branch)/unknown", displayName: Self.unknownDateName))
        case .day(let day):
            let year = "\(branch)/\(day.yearString)"
            let month = "\(year)/\(day.monthString)"
            levels.append(FolderLevel(logicalPath: year, displayName: day.yearString))
            levels.append(FolderLevel(logicalPath: month, displayName: day.monthString))
            if placement.category == .camera, dayPromoted {
                levels.append(FolderLevel(logicalPath: "\(month)/\(day.description)", displayName: Self.dayFolderName(day, placeName: placeName)))
            }
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
                FolderLevel(logicalPath: "\(group)/\(day.yearString)", displayName: day.yearString),
                FolderLevel(logicalPath: "\(group)/\(day.yearString)/\(day.monthString)", displayName: day.monthString),
            ]
        case let .byPlace(countryKey, countryName, areaKey, areaName, day):
            let root = "view/byPlace"
            let country = "\(root)/\(countryKey)"
            let area = "\(country)/\(areaKey)"
            return [
                FolderLevel(logicalPath: root, displayName: Self.byPlaceName),
                FolderLevel(logicalPath: country, displayName: NameSanitizer.sanitize(countryName)),
                FolderLevel(logicalPath: area, displayName: NameSanitizer.sanitize(areaName)),
                FolderLevel(logicalPath: "\(area)/\(day.yearString)", displayName: day.yearString),
            ]
        case let .favorites(day):
            let root = "view/favorites"
            return [
                FolderLevel(logicalPath: root, displayName: Self.favoritesName),
                FolderLevel(logicalPath: "\(root)/\(day.yearString)", displayName: day.yearString),
            ]
        }
    }
}
