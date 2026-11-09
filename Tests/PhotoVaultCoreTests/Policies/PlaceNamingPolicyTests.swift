import Foundation
import Testing
@testable import PhotoVaultCore

@Suite struct PlaceNamingPolicyTests {
    let day = ArchiveDay(year: 2025, month: 3, day: 1)!
    let tz = PolicyFixtures.vietnam
    var afterSixHours: Date { day.endDate(in: tz).addingTimeInterval(6 * 3600) }

    let daLat = GeoPoint(latitude: 11.9404, longitude: 108.4583)
    let xuanHuong = GeoPoint(latitude: 11.9500, longitude: 108.4400)
    let hanoi = GeoPoint(latitude: 21.0285, longitude: 105.8542)
    let tokyo = GeoPoint(latitude: 35.6762, longitude: 139.6503)

    func place(_ iso: String? = "VN", _ country: String? = "Vietnam", _ area: String? = "Lam Dong", _ city: String? = "Da Lat") -> GeoPlace {
        GeoPlace(isoCountryCode: iso, country: country, administrativeArea: area, locality: city)
    }

    func evaluate(
        _ assets: [PlaceAsset], en: [GeoPoint: GeoPlace] = [:], display: [GeoPoint: GeoPlace] = [:], includeHidden: Bool = false,
        home: String = "VN", now: Date? = nil
    ) -> PlaceNamingResult {
        PlaceNamingPolicy.evaluate(PlaceNamingInput(
            assets: assets, includeHidden: includeHidden,
            englishGeocodes: Dictionary(en.map { (GeoCell($0.key), $0.value) }, uniquingKeysWith: { $1 }),
            localGeocodes: Dictionary(display.map { (GeoCell($0.key), $0.value) }, uniquingKeysWith: { $1 }),
            homeCountryCode: home, day: day, archiveTimeZone: tz, now: now ?? afterSixHours
        ))
    }

    func pa(_ point: GeoPoint?, hidden: Bool = false, deleted: Bool = false) -> PlaceAsset {
        PlaceAsset(location: point, isHidden: hidden, isDeleted: deleted)
    }

    @Test func daLatWithIphoneAndRawWithoutGpsIsNamed() {
        let assets = [pa(daLat), pa(nil)]
        let vi = place("VN", "Việt Nam", "Lâm Đồng", "Đà Lạt")
        let result = evaluate(assets, en: [daLat: place()], display: [daLat: vi])
        #expect(result.state == .named)
        #expect(result.placeKey == "VN|Lam Dong")
        #expect(result.placeName == "Đà Lạt")
        #expect(result.cellsToGeocode.isEmpty)
    }

    @Test func noGpsAtAllIsUnnamed() {
        #expect(evaluate([pa(nil), pa(nil)]).state == .unnamed)
        #expect(evaluate([]).state == .unnamed)
    }

    @Test func missingGeocodesWaitAndListTheCells() {
        let result = evaluate([pa(daLat), pa(xuanHuong)])
        #expect(result.state == .waitingGeocode)
        #expect(Set(result.cellsToGeocode) == [GeoCell(daLat), GeoCell(xuanHuong)])
        let onlyDisplayMissing = evaluate([pa(daLat)], en: [daLat: place()])
        #expect(onlyDisplayMissing.state == .waitingGeocode)
        #expect(onlyDisplayMissing.cellsToGeocode == [GeoCell(daLat)])
    }

    @Test func englishSpeakingCountriesNeedOnlyTheEnglishGeocode() {
        let london = GeoPoint(latitude: 51.5074, longitude: -0.1278)
        let uk = GeoPlace(isoCountryCode: "GB", country: "United Kingdom", administrativeArea: "England", locality: "London")
        let result = evaluate([pa(london)], en: [london: uk])
        #expect(result.state == .named)
        #expect(result.placeName == "London, United Kingdom")
    }

    @Test func twoProvincesAreUnnamedEvenWhileOtherCellsAreMissing() {
        let phuYen = GeoPoint(latitude: 11.9404, longitude: 108.5583)
        let result = evaluate([pa(daLat), pa(phuYen), pa(xuanHuong)], en: [daLat: place(), phuYen: place("VN", "Vietnam", "Khanh Hoa", "Nha Trang")])
        #expect(result.state == .unnamed)
    }

    @Test func sameProvinceDifferentCitiesUsesProvinceName() {
        let bao = GeoPoint(latitude: 11.5, longitude: 107.8)
        let en = [daLat: place(), bao: place("VN", "Vietnam", "Lam Dong", "Bao Loc")]
        let display = [daLat: place("VN", "Việt Nam", "Lâm Đồng", "Đà Lạt"), bao: place("VN", "Việt Nam", "Lâm Đồng", "Bảo Lộc")]
        let result = evaluate([pa(daLat), pa(bao)], en: en, display: display)
        #expect(result.state == .named)
        #expect(result.placeName == "Lâm Đồng")
        #expect(result.placeKey == "VN|Lam Dong")
    }

    @Test func foreignCountryGetsSuffix() {
        let japan = GeoPlace(isoCountryCode: "JP", country: "Japan", administrativeArea: "Tokyo", locality: "Shibuya")
        let native = GeoPlace(isoCountryCode: "JP", country: "日本", administrativeArea: "東京都", locality: "渋谷区")
        let result = evaluate([pa(tokyo)], en: [tokyo: japan], display: [tokyo: native])
        #expect(result.placeName == "Shibuya (渋谷区), Japan")
        #expect(result.placeKey == "JP|Tokyo")
        let abroadHome = evaluate([pa(tokyo)], en: [tokyo: japan], display: [tokyo: native], home: "jp")
        #expect(abroadHome.placeName == "Shibuya (渋谷区)")
    }

    @Test func seaOrMissingAdministrativeAreaIsIgnoredOrUnnamed() {
        let sea = GeoPoint(latitude: 10.0, longitude: 109.5)
        let seaPlace = GeoPlace(isoCountryCode: nil, country: nil, administrativeArea: nil, locality: nil)
        #expect(evaluate([pa(sea)], en: [sea: seaPlace]).state == .unnamed)
        let mixed = evaluate([pa(sea), pa(daLat)], en: [sea: seaPlace, daLat: place()], display: [daLat: place()])
        #expect(mixed.state == .named)
        #expect(mixed.placeKey == "VN|Lam Dong")
        let noIso = evaluate([pa(daLat)], en: [daLat: place(nil)])
        #expect(noIso.state == .unnamed)
    }

    @Test func boundingBoxOverThreeHundredKmIsUnnamedWithoutGeocoding() {
        let result = evaluate([pa(daLat), pa(hanoi)])
        #expect(result.state == .unnamed)
        #expect(result.cellsToGeocode.isEmpty)
    }

    @Test func boundingBoxJustUnderLimitIsKept() {
        // About 2.0 degrees of latitude is roughly 222 km.
        let far = GeoPoint(latitude: 13.94, longitude: 108.4583)
        let result = evaluate([pa(daLat), pa(far)])
        #expect(result.state == .waitingGeocode)
    }

    @Test func hiddenAssetsAreExcludedUnlessHiddenUploadIsOn() {
        let hiddenSpot = hanoi
        let assets = [pa(daLat), pa(hiddenSpot, hidden: true)]
        let en = [daLat: place()]
        #expect(evaluate(assets, en: en, display: [daLat: place()]).state == .named)
        #expect(evaluate(assets, en: en, includeHidden: true).state == .unnamed)
        let onlyHidden = evaluate([pa(daLat, hidden: true)], en: en)
        #expect(onlyHidden.state == .unnamed)
    }

    @Test func deletedAssetsAreExcluded() {
        let result = evaluate([pa(daLat), pa(hanoi, deleted: true)], en: [daLat: place()], display: [daLat: place()])
        #expect(result.state == .named)
        #expect(evaluate([pa(daLat, deleted: true)]).state == .unnamed)
    }

    @Test func dayThatEndedLessThanSixHoursAgoIsPending() {
        let end = day.endDate(in: tz)
        let en = [daLat: place()]
        let early = evaluate([pa(daLat)], en: en, display: en, now: end.addingTimeInterval(6 * 3600 - 1))
        #expect(early.state == .pending && early.placeName == nil)
        let stillOngoing = evaluate([pa(daLat)], en: en, display: en, now: end.addingTimeInterval(-3600))
        #expect(stillOngoing.state == .pending)
        let ready = evaluate([pa(daLat)], en: en, display: en, now: end.addingTimeInterval(6 * 3600))
        #expect(ready.state == .named)
    }

    @Test func morethanThirtyCellsPickThirtyIncludingExtremes() {
        var cells = Set<GeoCell>()
        for i in 0..<60 { cells.insert(GeoCell(latIndex: 1000 + (i * 7) % 41, lonIndex: 10_800 + i)) }
        let chosen = PlaceNamingPolicy.representativeCells(cells)
        #expect(chosen.count == 30)
        #expect(Set(chosen).isSubset(of: cells))
        #expect(chosen.contains { $0.latIndex == cells.map(\.latIndex).max()! })
        #expect(chosen.contains { $0.lonIndex == 10_800 })
        #expect(chosen.contains { $0.lonIndex == 10_859 })
        #expect(chosen.contains { $0.latIndex == cells.map(\.latIndex).min()! })
        #expect(chosen == PlaceNamingPolicy.representativeCells(cells))
        #expect(PlaceNamingPolicy.representativeCells(Set(cells.prefix(10))).count == 10)
    }

    @Test func haversineIsAccurate() {
        let paris = GeoPoint(latitude: 48.8566, longitude: 2.3522)
        let london = GeoPoint(latitude: 51.5074, longitude: -0.1278)
        #expect(abs(PlaceNamingPolicy.haversineKm(paris, london) - 343.5) < 2)
    }
}
