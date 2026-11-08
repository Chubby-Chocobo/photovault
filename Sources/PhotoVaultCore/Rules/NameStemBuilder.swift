import Foundation

/// Builds `name_stem` and file names (FR-41).
public struct NameStemBuilder: Sendable {
    public let timeZone: TimeZone
    public let utiResolver: any UTIResolver

    public init(timeZone: TimeZone, utiResolver: any UTIResolver) {
        self.timeZone = timeZone
        self.utiResolver = utiResolver
    }

    /// Filename without its last extension, sanitized and limited to 120 bytes.
    public static func originalStem(of filename: String) -> String {
        let name = (filename as NSString).deletingPathExtension
        return NameSanitizer.sanitize(name.isEmpty ? filename : name, maxBytes: NameSanitizer.maxStemBytes)
    }

    /// Extension of `filename` with its case preserved, or nil.
    public static func originalExtension(of filename: String) -> String? {
        let ext = (filename as NSString).pathExtension
        return ext.isEmpty ? nil : ext
    }

    /// `YYYY-MM-DD HH.mm.ss_<stem>` in the archive timezone, or `undated_<stem>`.
    public func baseStem(creationDate: Date?, primaryFilename: String) -> String {
        let stem = Self.originalStem(of: primaryFilename)
        guard let creationDate else { return "undated_" + stem }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: creationDate)
        let prefix = String(format: "%04d-%02d-%02d %02d.%02d.%02d_", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        return prefix + stem
    }

    /// First of `base`, `base (1)`, `base (2)`… whose collision key is not in `taken`.
    public static func uniqueStem(base: String, taken: Set<String>) -> String {
        if !taken.contains(NameSanitizer.collisionKey(base)) { return base }
        var n = 1
        while taken.contains(NameSanitizer.collisionKey("\(base) (\(n))")) { n += 1 }
        return "\(base) (\(n))"
    }

    /// Upper-cased extension derived from the UTI, e.g. `HEIC`.
    public func utiExtension(_ uti: String) -> String {
        (utiResolver.preferredExtension(for: uti) ?? "bin").uppercased()
    }

    /// File name for one resource or sidecar of an asset with `stem`.
    public func fileName(stem: String, resource: ResourceRecord) -> String {
        let ext: String
        let suffix: String
        switch resource.kind {
        case .original:
            ext = Self.originalExtension(of: resource.originalFilename) ?? utiExtension(resource.uti)
            suffix = ""
        case .edited:
            ext = utiExtension(resource.uti)
            suffix = " (edited)"
        case .sidecarJson:
            ext = "json"
            suffix = ""
        case .sidecarXmp:
            ext = "xmp"
            suffix = ""
        }
        return Self.fit(stem: stem, suffix: suffix + "." + ext)
    }

    public static func sidecarName(stem: String, type: ResourceType) -> String {
        fit(stem: stem, suffix: type == .sidecarXmp ? ".xmp" : ".json")
    }

    /// Keeps the whole name within the 240-byte component limit by shortening the stem.
    static func fit(stem: String, suffix: String) -> String {
        let budget = NameSanitizer.maxComponentBytes - suffix.utf8.count
        return NameSanitizer.truncate(stem, maxBytes: max(budget, 1)) + suffix
    }
}
