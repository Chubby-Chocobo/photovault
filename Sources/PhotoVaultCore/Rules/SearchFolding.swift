import Foundation

/// The one search folding of the app: lowercase without diacritics, so "anh" finds "Ảnh". `đ` has no
/// decomposition, so it is folded by hand.
public enum SearchFolding {
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "vi"))
            .replacingOccurrences(of: "đ", with: "d")  // l10n: verbatim
    }
}
