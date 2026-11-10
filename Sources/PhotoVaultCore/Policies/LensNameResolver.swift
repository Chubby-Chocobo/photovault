import Foundation

/// Folder name and grouping key of a lens for the By lens view. The name is the EXIF lens model
/// with spacing tidied, the "back ... camera" wording of phone lenses shortened and apertures
/// written `f1.78`, so the name needs no character replaced when it becomes a folder name.
public enum LensNameResolver {
    /// "<model> back <...> camera <rest>" and "<model> front <...> camera <rest>".
    private static let back = try! NSRegularExpression(pattern: #"^(.+?) back (?:.*?)camera (.+)$"#, options: .caseInsensitive)
    private static let front = try! NSRegularExpression(pattern: #"^(.+?) front (?:.*?)camera (.+)$"#, options: .caseInsensitive)
    private static let aperture = try! NSRegularExpression(pattern: #"\b([fF])/(?=\d)"#)
    /// Cameras that know nothing about the lens write zeros: "0.0 mm f/0.0".
    private static let emptyFocal = try! NSRegularExpression(pattern: #"^0(?:\.0*)? ?mm f/?0(?:\.0*)?$"#, options: .caseInsensitive)

    /// nil when the lens is missing, blank or a placeholder.
    public static func name(for lensModel: String?) -> String? {
        let tidy = (lensModel ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard tidy.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        var range = NSRange(tidy.startIndex..., in: tidy)
        if emptyFocal.firstMatch(in: tidy, range: range) != nil { return nil }
        var shortened = tidy
        for (expression, middle) in [(back, ""), (front, " front")] {
            if let match = expression.firstMatch(in: tidy, range: range),
               let model = Range(match.range(at: 1), in: tidy), let rest = Range(match.range(at: 2), in: tidy) {
                shortened = "\(tidy[model])\(middle) \(tidy[rest])"
                break
            }
        }
        range = NSRange(shortened.startIndex..., in: shortened)
        return aperture.stringByReplacingMatches(in: shortened, range: range, withTemplate: "$1")
    }

    /// Stable, case-insensitive key of the folder name; it names the folder in the logical path.
    /// Two lens strings that would get the same folder name get the same key.
    public static func key(for lensModel: String?) -> String? {
        name(for: lensModel).map {
            DeviceNameResolver.groupId(forKey: NameSanitizer.sanitize($0).lowercased().precomposedStringWithCanonicalMapping)
        }
    }
}
