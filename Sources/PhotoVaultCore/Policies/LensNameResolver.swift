import Foundation

/// Folder name and grouping key of a lens for the By lens view. The name is the EXIF lens model
/// with spacing tidied and Apple's "back ... camera" wording shortened.
public enum LensNameResolver {
    /// "<model> back <...> camera <rest>" and "<model> front <...> camera <rest>".
    private static let back = try! NSRegularExpression(pattern: #"^(.+?) back (?:.*?)camera (.+)$"#, options: .caseInsensitive)
    private static let front = try! NSRegularExpression(pattern: #"^(.+?) front (?:.*?)camera (.+)$"#, options: .caseInsensitive)

    /// nil when the lens is missing or blank.
    public static func name(for lensModel: String?) -> String? {
        let tidy = (lensModel ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !tidy.isEmpty else { return nil }
        let range = NSRange(tidy.startIndex..., in: tidy)
        for (expression, middle) in [(back, ""), (front, " front")] {
            if let match = expression.firstMatch(in: tidy, range: range),
               let model = Range(match.range(at: 1), in: tidy), let rest = Range(match.range(at: 2), in: tidy) {
                return "\(tidy[model])\(middle) \(tidy[rest])"
            }
        }
        return tidy
    }

    /// Stable, case-insensitive key of the normalised name; it names the folder in the logical path.
    public static func key(for lensModel: String?) -> String? {
        name(for: lensModel).map { DeviceNameResolver.groupId(forKey: $0.lowercased()) }
    }
}
