import Foundation

/// Formatting of where an import came from. Display strings for the owner only; never logged.
public enum ImportLocationPath {
    /// The real home directory. `NSHomeDirectory()` is the sandbox container, which is not what the owner sees.
    public static var currentHome: String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        return ""
    }

    /// `path` with `home` shown as `~`. Other locations (external volumes, NAS) stay absolute.
    public static func mac(_ path: String, home: String = currentHome) -> String {
        var home = home
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Dropbox `path_display`; the whole account (`""`) is "/".
    public static func dropbox(_ pathDisplay: String) -> String { pathDisplay.isEmpty ? "/" : pathDisplay }

    public static func dropboxWebURL(_ pathDisplay: String) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        guard let encoded = pathDisplay.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        let tail = pathDisplay.isEmpty || pathDisplay == "/" ? "" : (pathDisplay.hasPrefix("/") ? encoded : "/" + encoded)
        return URL(string: "https://www.dropbox.com/home" + tail)
    }

    /// Drive ids are letters, digits, `-` and `_`; anything else is not turned into a link.
    public static func driveFolderURL(id: String) -> URL? {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return URL(string: "https://drive.google.com/drive/folders/" + id)
    }
}

/// What an import row shows about the source's location. Built from the stored config; a Mac folder without a
/// stored path (an import made before it was recorded) has none and is derived from its bookmark by the app.
public struct ImportLocation: Hashable, Sendable {
    /// Paths to show; the first is the headline.
    public var paths: [String]
    /// Picked items beyond the first (Drive).
    public var othersCount: Int
    public var webURL: URL?

    public init(paths: [String], othersCount: Int = 0, webURL: URL? = nil) {
        self.paths = paths
        self.othersCount = othersCount
        self.webURL = webURL
    }

    public static func make(kind: SourceKind, config: SourceConfig) -> ImportLocation? {
        switch kind {
        case .localFolder:
            guard let paths = config.locationPaths, !paths.isEmpty else { return nil }
            return ImportLocation(paths: paths)
        case .dropbox:
            guard let root = config.remoteItems?.first else { return nil }
            return ImportLocation(paths: [ImportLocationPath.dropbox(root)], webURL: ImportLocationPath.dropboxWebURL(root))
        case .googleDrive:
            guard let paths = config.locationPaths, !paths.isEmpty else { return nil }
            let others = max(paths.count, config.remoteItems?.count ?? 0) - 1
            let link = config.locationURL.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" && $0.host == "drive.google.com" ? $0 : nil }
            return ImportLocation(paths: paths, othersCount: others, webURL: link)
        case .photos:
            return nil
        }
    }
}

extension ImportLocation: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "ImportLocation(redacted)" }
    public var debugDescription: String { description }
}
