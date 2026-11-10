import Foundation
import PhotoVaultCore

/// Text for the "where did this import come from" line of an import row. Paths are shown in the app only; they
/// are never logged, never put in activity rows and never in notifications.
public enum ImportLocationText {
    public static func headline(_ location: ImportLocation) -> String { location.paths.first ?? "" }

    /// "+3 mục khác" for the picked items not shown in the headline.
    public static func othersLabel(_ location: ImportLocation) -> String? {
        guard location.othersCount > 0 else { return nil }
        let number = VietnameseFormat.integer(location.othersCount)
        return tr(vi: "+\(number) mục khác", en: "+\(number) more")
    }

    /// Every stored path, one per line, then the count of items that have no path of their own.
    public static func tooltip(_ location: ImportLocation?) -> String? {
        guard let location, !location.paths.isEmpty else { return nil }
        // The paths listed here are already counted in `othersCount`; only the picks without a path remain.
        let unlisted = location.othersCount - (location.paths.count - 1)
        var lines = location.paths
        if unlisted > 0 { lines.append(othersLabel(ImportLocation(paths: location.paths, othersCount: unlisted)) ?? "") }
        return lines.joined(separator: "\n")
    }

    /// The headline cut to `budget` characters by whole components, and the "+N" label that is never cut.
    public static func display(_ location: ImportLocation, budget: Int) -> (path: String, others: String?) {
        (ImportLocationShortener.shorten(headline(location), budget: budget), othersLabel(location))
    }

    public static var copyTitle: String { tr(vi: "Sao chép đường dẫn", en: "Copy path") }
    public static var revealTitle: String { tr(vi: "Hiện trong Finder", en: "Show in Finder") }
    public static var openOnWebTitle: String { tr(vi: "Mở trên web", en: "Open on the web") }

    /// The stored location of a Mac folder, or, for an import made before paths were recorded, the path its
    /// bookmark resolves to now.
    public static func macLocation(stored: ImportLocation?, resolvedPath: String?, home: String = ImportLocationPath.currentHome) -> ImportLocation? {
        if let stored { return stored }
        guard let resolvedPath, !resolvedPath.isEmpty else { return nil }
        return ImportLocation(paths: [ImportLocationPath.mac(resolvedPath, home: home)])
    }
}
