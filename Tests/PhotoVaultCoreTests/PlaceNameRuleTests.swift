import Foundation
import Testing
@testable import PhotoVaultCore

struct PlaceNameRuleTests {
    @Test func secondLocaleIsVietnameseAtHomeAndTheNativeLanguageAbroad() {
        #expect(PlaceNameRule.secondLocale(country: "VN") == "vi")
        #expect(PlaceNameRule.secondLocale(country: "jp") == "ja")
        #expect(PlaceNameRule.secondLocale(country: "TH") == "th")
        #expect(PlaceNameRule.secondLocale(country: "FR") == "fr")
        #expect(PlaceNameRule.secondLocale(country: "CN") == "zh-Hans")
        #expect(PlaceNameRule.secondLocale(country: "TW") == "zh-Hant")
        #expect(PlaceNameRule.secondLocale(country: "GB") == nil)
        #expect(PlaceNameRule.secondLocale(country: "US") == nil)
        #expect(PlaceNameRule.secondLocale(country: "") == nil)
    }

    @Test func vietnamUsesVietnameseNamesAndAnEnglishCountry() {
        let english = GeoPlace(isoCountryCode: "VN", country: "Vietnam", administrativeArea: "Lam Dong", locality: "Da Lat")
        let local = GeoPlace(isoCountryCode: "VN", country: "Việt Nam", administrativeArea: "Lâm Đồng", locality: "Đà Lạt")
        #expect(PlaceNameRule.display(english: english, local: local)
            == GeoPlace(isoCountryCode: "VN", country: "Vietnam", administrativeArea: "Lâm Đồng", locality: "Đà Lạt"))
    }

    @Test func abroadUsesEnglishWithTheNativeNameInParentheses() {
        let english = GeoPlace(isoCountryCode: "JP", country: "Japan", administrativeArea: "Kyoto", locality: "Kyoto")
        let local = GeoPlace(isoCountryCode: "JP", country: "日本", administrativeArea: "京都府", locality: "京都市")
        #expect(PlaceNameRule.display(english: english, local: local)
            == GeoPlace(isoCountryCode: "JP", country: "Japan", administrativeArea: "Kyoto (京都府)", locality: "Kyoto (京都市)"))
    }

    @Test func noParenthesesWhenTheNativeNameIsTheSame() {
        let english = GeoPlace(isoCountryCode: "FR", country: "France", administrativeArea: "Île-de-France", locality: "Paris")
        let local = GeoPlace(isoCountryCode: "FR", country: "France", administrativeArea: "ILE-DE-FRANCE", locality: "Paris")
        #expect(PlaceNameRule.display(english: english, local: local).administrativeArea == "Île-de-France")
        #expect(PlaceNameRule.display(english: english, local: local).locality == "Paris")
        let london = GeoPlace(isoCountryCode: "GB", country: "United Kingdom", administrativeArea: "England", locality: "London")
        #expect(PlaceNameRule.display(english: london, local: nil) == london)
    }

    @Test func missingLocalAnswerFallsBackToEnglish() {
        let english = GeoPlace(isoCountryCode: "VN", country: "Vietnam", administrativeArea: "Lam Dong", locality: nil)
        #expect(PlaceNameRule.display(english: english, local: nil) == english)
    }
}
