import Foundation
import Testing
@testable import PhotoVaultCore

struct PlaceNamePrefixTests {
    @Test(arguments: [
        ("Thành phố Hà Nội", "Hà Nội"), ("thành phố Hà Nội", "Hà Nội"), ("TP. Hồ Chí Minh", "Hồ Chí Minh"),
        ("TP.Hồ Chí Minh", "Hồ Chí Minh"), ("Tỉnh Lâm Đồng", "Lâm Đồng"), ("Thành phố Đà Lạt", "Đà Lạt"),
        ("Lâm Đồng", "Lâm Đồng"), ("P. Cửa Nam", "P. Cửa Nam"), ("Đặc khu Phú Quốc", "Đặc khu Phú Quốc"), ("Thành phố", "Thành phố"),
    ])
    func vietnameseProvinceAndCityPrefixesAreDropped(_ name: String, _ expected: String) {
        #expect(PlaceNameRule.withoutProvincePrefix(name) == expected)
    }

    @Test func dayAndViewNamesUseTheShortVietnameseName() {
        let english = GeoPlace(isoCountryCode: "VN", country: "Vietnam", administrativeArea: "Hanoi", locality: "Hanoi")
        let local = GeoPlace(isoCountryCode: "VN", country: "Việt Nam", administrativeArea: "Thành phố Hà Nội", locality: "Thành phố Hà Nội")
        let display = PlaceNameRule.display(english: english, local: local)
        #expect(display.administrativeArea == "Hà Nội")
        #expect(display.locality == "Hà Nội")
        #expect(display.country == "Vietnam")
    }

    @Test func foreignNamesKeepTheirOwnWording() {
        let english = GeoPlace(isoCountryCode: "JP", country: "Japan", administrativeArea: "Kyoto", locality: "Kyoto")
        let local = GeoPlace(isoCountryCode: "JP", country: "日本", administrativeArea: "京都府", locality: "京都市")
        #expect(PlaceNameRule.display(english: english, local: local).locality == "Kyoto (京都市)")
    }

    @Test func theCountryOnlyFallbackNamesTheCountryInEnglish() {
        let fallback = GeoPlace(isoCountryCode: "VN", country: nil, administrativeArea: "Vietnam", locality: nil)
        let local = GeoPlace(isoCountryCode: "VN", country: nil, administrativeArea: "Việt Nam", locality: nil)
        let display = PlaceNameRule.display(english: fallback, local: local)
        #expect(display.administrativeArea == "Vietnam")
        #expect(display.country == "Vietnam")
    }

    @Test func aVietnameseAnswerAbroadIsNotTakenForTheNativeName() {
        let japan = GeoPlace(isoCountryCode: "JP", country: "Japan", administrativeArea: "Kyoto", locality: "Kyoto")
        let inVietnamese = GeoPlace(isoCountryCode: "JP", country: "Nhật Bản", administrativeArea: "Kyoto", locality: "Kyoto")
        #expect(PlaceNameRule.display(english: japan, local: inVietnamese).locality == "Kyoto")
        let english = GeoPlace(isoCountryCode: "PH", country: "Philippines", administrativeArea: "Metro Manila", locality: "Manila")
        let systemLanguage = GeoPlace(isoCountryCode: "PH", country: "Philippines", administrativeArea: "Vùng thủ đô Quốc gia", locality: "Manila")
        #expect(PlaceNameRule.display(english: english, local: systemLanguage).administrativeArea == "Metro Manila")
    }

    @Test func nativeNamesWithLettersVietnameseAlsoUsesAreKept() {
        let romania = GeoPlace(isoCountryCode: "RO", country: "Romania", administrativeArea: "Bucharest", locality: "Bucharest")
        let romanian = GeoPlace(isoCountryCode: "RO", country: "România", administrativeArea: "București", locality: "București")
        #expect(PlaceNameRule.display(english: romania, local: romanian).locality == "Bucharest (București)")
        let croatia = GeoPlace(isoCountryCode: "HR", country: "Croatia", administrativeArea: "Medimurje County", locality: nil)
        let croatian = GeoPlace(isoCountryCode: "HR", country: "Hrvatska", administrativeArea: "Međimurska županija", locality: nil)
        #expect(PlaceNameRule.display(english: croatia, local: croatian).administrativeArea == "Medimurje County (Međimurska županija)")
    }

    @Test func metadataFieldsGetOnePlainName() {
        let english = GeoPlace(isoCountryCode: "JP", country: "Japan", administrativeArea: "Kyoto", locality: "Kyoto")
        let local = GeoPlace(isoCountryCode: "JP", country: "日本", administrativeArea: "京都府", locality: "京都市")
        #expect(PlaceNameRule.display(english: english, local: local, withNative: false).locality == "Kyoto")
        let vn = GeoPlace(isoCountryCode: "VN", country: "Vietnam", administrativeArea: "Hanoi", locality: nil)
        let vnLocal = GeoPlace(isoCountryCode: "VN", country: "Việt Nam", administrativeArea: "Thành phố Hà Nội", locality: nil)
        #expect(PlaceNameRule.display(english: vn, local: vnLocal, withNative: false).administrativeArea == "Hà Nội")
    }
}
