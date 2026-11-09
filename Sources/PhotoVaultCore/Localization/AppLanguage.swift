import Foundation

/// A language the interface is written in. Destination content (folder names, sidecars) never
/// depends on it.
public enum AppLanguage: String, CaseIterable, Sendable {
    case vi
    case en
}

/// What the owner picked in Settings: a language, or whatever the Mac prefers.
public enum InterfaceLanguageChoice: String, CaseIterable, Sendable {
    case system
    case vi
    case en

    /// The language to show. `system` follows the Mac's first preferred language: Vietnamese when
    /// that is Vietnamese, English otherwise.
    public func resolved(preferredLanguages: [String]) -> AppLanguage {
        switch self {
        case .vi: return .vi
        case .en: return .en
        case .system:
            let first = preferredLanguages.first?.lowercased() ?? ""
            return first == "vi" || first.hasPrefix("vi-") || first.hasPrefix("vi_") ? .vi : .en
        }
    }
}
