import Foundation

/// How a place is named on destinations (owner decision, 2026-11-09): the country in English; a
/// province or city in Vietnam in Vietnamese; abroad in English with the native name in parentheses
/// when it differs ("Kyoto (京都市)"). Each cell is geocoded in `en` and once in `secondLocale`.
public enum PlaceNameRule {
    /// The language of the second geocode for a country: Vietnamese in Vietnam, otherwise the
    /// country's primary language; nil when that is English (the English answer is enough).
    public static func secondLocale(country iso: String) -> String? {
        let iso = iso.trimmingCharacters(in: .whitespaces).uppercased()
        guard iso.count == 2 else { return nil }
        if iso == "VN" { return "vi" }
        let language = Locale.Language(identifier: "und-\(iso)")
        let parts = language.maximalIdentifier.split(separator: "-")
        guard let code = parts.first.map(String.init), code != "und", code != "en" else { return nil }
        // Chinese differs by script, which the geocoder needs to tell simplified from traditional.
        if code == "zh", parts.count > 1 { return "zh-\(parts[1])" }
        return code
    }

    /// The names to use for a cell, from its English answer and its answer in `secondLocale`.
    /// `withNative: false` leaves out the parenthesised native name, for metadata fields (sidecars,
    /// Drive descriptions) where one plain name reads better than two.
    public static func display(english: GeoPlace, local: GeoPlace?, withNative: Bool = true) -> GeoPlace {
        let country = english.country.flatMap(nonEmpty) ?? englishCountryName(english.isoCountryCode)
        // Country-only fallback (no province from the geocoder): the area holds a country name,
        // and country names are always English.
        if english.country == nil, english.administrativeArea != nil {
            return GeoPlace(isoCountryCode: english.isoCountryCode, country: country, administrativeArea: english.administrativeArea, locality: nil)
        }
        let inVietnam = english.isoCountryCode?.uppercased() == "VN"
        // Abroad, an answer whose country is the Vietnamese name of that country means the geocoder
        // ignored the requested language and used the Mac's: it is not the native name.
        let local = !inVietnam && local.map { answeredInVietnamese($0, iso: english.isoCountryCode) } == true ? nil : local
        func name(_ english: String?, _ local: String?) -> String? {
            let english = english.flatMap(nonEmpty)
            let local = local.flatMap(nonEmpty)
            if inVietnam { return (local ?? english).map(withoutProvincePrefix) }
            guard let english else { return local }
            guard withNative, let local, fold(local) != fold(english) else { return english }
            return "\(english) (\(local))"
        }
        return GeoPlace(
            isoCountryCode: english.isoCountryCode, country: country,
            administrativeArea: name(english.administrativeArea, local?.administrativeArea),
            locality: name(english.locality, local?.locality))
    }

    /// Province- and city-level prefixes Apple puts in front of Vietnamese names. Ward and commune
    /// prefixes ("P. Cửa Nam", "X. …", "Đặc khu …") stay: the owner chose to keep them.
    static let provincePrefixes = ["Thành phố ", "TP. ", "TP.", "TP ", "Tỉnh ", "Thủ đô "]

    /// "Thành phố Hà Nội" → "Hà Nội", "Tỉnh Lâm Đồng" → "Lâm Đồng"; other names unchanged.
    static func withoutProvincePrefix(_ name: String) -> String {
        for prefix in provincePrefixes where name.count > prefix.count && name.lowercased().hasPrefix(prefix.lowercased()) {
            let rest = name.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        return name
    }

    /// "Vietnam", "Japan" from the ISO code, for answers that lost their country name.
    static func englishCountryName(_ iso: String?) -> String? {
        guard let iso, !iso.isEmpty else { return nil }
        return Locale(identifier: "en_US").localizedString(forRegionCode: iso.uppercased())
    }

    /// True when the answer came back in Vietnamese: its country is the Vietnamese name of the
    /// country ("Nhật Bản"), or, where that name is the same as the English one ("Philippines"), its
    /// names use letters found only in Vietnamese.
    private static func answeredInVietnamese(_ place: GeoPlace, iso: String?) -> Bool {
        guard let iso, let vietnamese = Locale(identifier: "vi").localizedString(forRegionCode: iso.uppercased()) else { return false }
        let english = englishCountryName(iso) ?? ""
        if fold(vietnamese) != fold(english) {
            return place.country.flatMap(nonEmpty).map { fold($0) == fold(vietnamese) } ?? false
        }
        return [place.locality, place.administrativeArea].contains { name in
            (name ?? "").lowercased().contains { vietnameseOnlyLetters.contains($0) }
        }
    }

    /// Letters no other language written in Latin script uses: ơ, ư, the hook above, and a tone mark
    /// on top of a circumflex or breve.
    private static let vietnameseOnlyLetters = Set("ơớờởỡợưứừửữựảẻỉỏủỷẳẩểổởửắằẵặấầẫậếềễệốồỗộỵ")

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
