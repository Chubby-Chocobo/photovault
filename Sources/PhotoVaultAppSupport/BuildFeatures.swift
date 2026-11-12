import Foundation

/// Reads build-time feature switches that arrive through Info.plist values.
public enum BuildFeatures {
    /// The browser Drive import needs a Google client ID and a build that includes it.
    public static func googleBrowserImportEnabled(clientID: String, flag: Bool) -> Bool {
        !clientID.trimmingCharacters(in: .whitespaces).isEmpty && flag
    }

    /// True only for an explicit yes. An empty value or one Xcode left unexpanded (`$(NAME)`) is off.
    public static func isOn(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        guard let text = value as? String else { return false }
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "yes", "1", "true": return true
        default: return false
        }
    }
}
