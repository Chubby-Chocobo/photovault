import Foundation
import Testing
@testable import PhotoVaultCore

@Suite struct PlaceSplitPolicyTests {
    let day = ArchiveDay(year: 2025, month: 3, day: 1)!
    let tz = PolicyFixtures.vietnam
    var dayStart: Date { day.endDate(in: tz).addingTimeInterval(-86_400) }
    var afterSixHours: Date { day.endDate(in: tz).addingTimeInterval(6 * 3600) }

    let hanoi = GeoPoint(latitude: 21.0285, longitude: 105.8542)
    let ninhBinh = GeoPoint(latitude: 20.2506, longitude: 105.9745)
    let daLat = GeoPoint(latitude: 11.9404, longitude: 108.4583)
    let saPa = GeoPoint(latitude: 22.3364, longitude: 103.8438)
    let sea = GeoPoint(latitude: 15.0, longitude: 112.0)
    let tokyo = GeoPoint(latitude: 35.6762, longitude: 139.6503)

    func enPlace(_ area: String?, iso: String = "VN", country: String? = "Vietnam") -> GeoPlace {
        GeoPlace(isoCountryCode: iso, country: country, administrativeArea: area)
    }
    func viPlace(_ area: String) -> GeoPlace {
        GeoPlace(isoCountryCode: "VN", country: "Việt Nam", administrativeArea: area)
    }

    /// Both geocode answers for the provinces used below.
    var vnEnglish: [GeoPoint: GeoPlace] {
        [hanoi: enPlace("Hanoi"), ninhBinh: enPlace("Ninh Binh"), daLat: enPlace("Lam Dong"), saPa: enPlace("Lao Cai"),
         tokyo: enPlace("Tokyo", iso: "JP", country: "Japan")]
    }
    var vnLocal: [GeoPoint: GeoPlace] {
        [hanoi: viPlace("Thành phố Hà Nội"), ninhBinh: viPlace("Tỉnh Ninh Bình"), daLat: viPlace("Tỉnh Lâm Đồng"),
         saPa: viPlace("Tỉnh Lào Cai"),
         tokyo: GeoPlace(isoCountryCode: "JP", country: "日本", administrativeArea: "東京都")]
    }

    func hours(_ h: Double) -> Date { dayStart.addingTimeInterval(h * 3600) }

    func asset(_ id: String, _ point: GeoPoint?, at hour: Double? = 0, hidden: Bool = false, deleted: Bool = false) -> PlaceAsset {
        PlaceAsset(location: point, isHidden: hidden, isDeleted: deleted, id: id, creationDate: hour.map(hours))
    }

    func input(
        _ assets: [PlaceAsset], en: [GeoPoint: GeoPlace]? = nil, local: [GeoPoint: GeoPlace]? = nil,
        includeHidden: Bool = false, now: Date? = nil
    ) -> PlaceNamingInput {
        func keyed(_ d: [GeoPoint: GeoPlace]) -> [GeoCell: GeoPlace] {
            Dictionary(d.map { (GeoCell($0.key), $0.value) }, uniquingKeysWith: { $1 })
        }
        return PlaceNamingInput(
            assets: assets, includeHidden: includeHidden, englishGeocodes: keyed(en ?? vnEnglish),
            localGeocodes: keyed(local ?? vnLocal), homeCountryCode: "VN", day: day, archiveTimeZone: tz,
            now: now ?? afterSixHours)
    }

    func groups(_ result: PlaceSplitResult) -> [PlaceGroup] {
        if case .groups(let groups, _) = result { return groups }
        Issue.record("expected groups, got \(result)")
        return []
    }

    func unassigned(_ result: PlaceSplitResult) -> [String] {
        if case .groups(_, let ids) = result { return ids }
        return []
    }

    @Test func dayEndedFiveHoursAgoIsPending() {
        let now = day.endDate(in: tz).addingTimeInterval(5 * 3600)
        #expect(PlaceSplitPolicy.evaluate(input([asset("a", hanoi)], now: now)) == .pending)
    }

    @Test func oneProvinceDelegatesToTheNamingPolicy() {
        var assets = (0..<40).map { asset("h\($0)", GeoPoint(latitude: 21.0 + Double($0) * 0.011, longitude: 105.85), at: Double($0) / 10) }
        assets.append(asset("none", nil, at: 5))
        var en: [GeoPoint: GeoPlace] = [:]
        var local: [GeoPoint: GeoPlace] = [:]
        for a in assets { if let p = a.location { en[p] = enPlace("Hanoi"); local[p] = viPlace("Thành phố Hà Nội") } }
        let result = input(assets, en: en, local: local)
        let expected = PlaceNamingPolicy.evaluate(result)
        let got = groups(PlaceSplitPolicy.evaluate(result))
        #expect(got.count == 1)
        #expect(got[0].key == expected.placeKey)
        #expect(got[0].name == expected.placeName)
        #expect(got[0].state == expected.state)
        #expect(got[0].members == assets.map(\.id).sorted())
    }

    @Test func oneProvinceMatchesNamingPolicyForTransientStates() {
        let assets = [asset("a", daLat), asset("b", hanoi)]
        for (en, local) in [([:], [:]), ([daLat: enPlace("Lam Dong")], [:]),
                            ([daLat: enPlace("Lam Dong"), hanoi: enPlace("Lam Dong")], [:])] as [([GeoPoint: GeoPlace], [GeoPoint: GeoPlace])] {
            let i = input(assets, en: en, local: local)
            let expected = PlaceNamingPolicy.evaluate(i)
            let got = PlaceSplitPolicy.evaluate(i)
            if expected.state == .waitingGeocode {
                #expect(got == .waitingGeocode(expected.cellsToGeocode))
            } else {
                #expect(groups(got).first?.state == expected.state)
            }
        }
    }

    @Test func oneProvinceWithUncachedExtraCellIsStillDelegated() {
        let extra = GeoPoint(latitude: 11.9500, longitude: 108.4400)
        let assets = [asset("a", daLat), asset("b", extra)]
        let result = PlaceSplitPolicy.evaluate(input(assets, en: [daLat: enPlace("Lam Dong")], local: [daLat: viPlace("Tỉnh Lâm Đồng")]))
        let expected = PlaceNamingPolicy.evaluate(input(assets, en: [daLat: enPlace("Lam Dong")], local: [daLat: viPlace("Tỉnh Lâm Đồng")]))
        #expect(expected.state == .waitingGeocode)
        #expect(result == .waitingGeocode(expected.cellsToGeocode))
    }

    @Test func oneProvinceBoxOverThreeHundredKmIsUnnamed() {
        let assets = [asset("a", hanoi), asset("b", GeoPoint(latitude: 24.0, longitude: 105.0))]
        let faraway = GeoPoint(latitude: 24.0, longitude: 105.0)
        let got = groups(PlaceSplitPolicy.evaluate(input(assets, en: [hanoi: enPlace("Hanoi"), faraway: enPlace("Hanoi")], local: [:])))
        #expect(got.count == 1)
        #expect(got[0].state == .unnamed)
        #expect(got[0].name == nil && got[0].key == nil)
    }

    @Test func twoProvincesGiveTwoNamedGroupsLargestFirst() {
        let assets = (0..<10).map { asset("h\($0)", hanoi, at: Double($0)) } + (0..<3).map { asset("n\($0)", ninhBinh, at: 12 + Double($0)) }
        let got = groups(PlaceSplitPolicy.evaluate(input(assets)))
        #expect(got.map(\.name) == ["Hà Nội", "Ninh Bình"])
        #expect(got.map(\.key) == ["VN|Hanoi", "VN|Ninh Binh"])
        #expect(got.map(\.state) == [.named, .named])
        #expect(got[1].members == ["n0", "n1", "n2"])
    }

    @Test func returningToTheFirstProvinceKeepsOneGroupForIt() {
        let assets = [asset("a1", hanoi, at: 1), asset("b1", ninhBinh, at: 5), asset("a2", hanoi, at: 9)]
        let got = groups(PlaceSplitPolicy.evaluate(input(assets)))
        #expect(got.count == 2)
        #expect(got[0].members == ["a1", "a2"])
    }

    @Test func assetWithoutGpsJoinsTheNearestInTimeAndTiesGoToTheEarlier() {
        let assets = [asset("a", hanoi, at: 9), asset("b", ninhBinh, at: 15), asset("x", nil, at: 11), asset("y", nil, at: 12)]
        let got = groups(PlaceSplitPolicy.evaluate(input(assets)))
        let hanoiGroup = got.first { $0.key == "VN|Hanoi" }
        #expect(hanoiGroup?.members == ["a", "x", "y"])
        #expect(got.first { $0.key == "VN|Ninh Binh" }?.members == ["b"])
    }

    @Test func equalTimesGoToTheSmallerId() {
        let assets = [asset("a2", hanoi, at: 9), asset("a1", ninhBinh, at: 9), asset("x", nil, at: 10)]
        let got = groups(PlaceSplitPolicy.evaluate(input(assets)))
        #expect(got.first { $0.members.contains("x") }?.key == "VN|Ninh Binh")
    }

    @Test func seaCellJoinsByTimeAndHasNoGroupOfItsOwn() {
        let en = vnEnglish.merging([sea: GeoPlace(isoCountryCode: nil, country: nil, administrativeArea: nil)]) { $1 }
        let assets = [asset("a", hanoi, at: 1), asset("b", ninhBinh, at: 20), asset("s", sea, at: 19)]
        let got = groups(PlaceSplitPolicy.evaluate(input(assets, en: en)))
        #expect(got.count == 2)
        #expect(got.first { $0.key == "VN|Ninh Binh" }?.members == ["b", "s"])
    }

    @Test func hiddenGpsPhotoWhileHiddenIsOffHasNoGroup() {
        let assets = [asset("a", hanoi, at: 1), asset("b", ninhBinh, at: 20), asset("h", saPa, at: 3, hidden: true)]
        let off = groups(PlaceSplitPolicy.evaluate(input(assets)))
        #expect(off.count == 2)
        #expect(off.first { $0.key == "VN|Hanoi" }?.members == ["a", "h"])
        let on = groups(PlaceSplitPolicy.evaluate(input(assets, includeHidden: true)))
        #expect(on.count == 3)
    }

    @Test func deletedPhotoFormsNoGroupAndIsNoMember() {
        let assets = [asset("a", hanoi, at: 1), asset("b", ninhBinh, at: 2), asset("d", saPa, at: 3, deleted: true)]
        let got = groups(PlaceSplitPolicy.evaluate(input(assets)))
        #expect(got.count == 2)
        #expect(!got.flatMap(\.members).contains("d"))
    }

    @Test func uncachedThirdCellWaitsOnceTwoProvincesAreKnown() {
        let assets = [asset("a", hanoi), asset("b", ninhBinh), asset("c", saPa)]
        var en = vnEnglish
        en[saPa] = nil
        #expect(PlaceSplitPolicy.evaluate(input(assets, en: en)) == .waitingGeocode([GeoCell(saPa)]))
    }

    @Test func missingSecondLocaleForAGroupWaits() {
        let assets = [asset("a", hanoi), asset("b", ninhBinh)]
        var local = vnLocal
        local[ninhBinh] = nil
        #expect(PlaceSplitPolicy.evaluate(input(assets, local: local)) == .waitingGeocode([GeoCell(ninhBinh)]))
    }

    @Test func singlePhotoInAnotherProvinceIsItsOwnGroup() {
        let assets = (0..<5).map { asset("h\($0)", hanoi, at: Double($0)) } + [asset("c", daLat, at: 7)]
        let got = groups(PlaceSplitPolicy.evaluate(input(assets)))
        #expect(got.map(\.members.count) == [5, 1])
        #expect(got[1].name == "Lâm Đồng")
    }

    @Test func abroadGroupCarriesTheCountrySuffix() {
        let assets = [asset("a", hanoi, at: 1), asset("t", tokyo, at: 20)]
        let got = groups(PlaceSplitPolicy.evaluate(input(assets)))
        let abroad = got.first { $0.key == "JP|Tokyo" }
        #expect(abroad?.name?.hasSuffix(", Japan") == true || abroad?.name?.contains("Japan") == true)
        #expect(got.first { $0.key == "VN|Hanoi" }?.name == "Hà Nội")
    }

    @Test func liveAssetWithoutCreationDateIsUnassigned() {
        let assets = [asset("a", hanoi, at: 1), asset("b", ninhBinh, at: 2), asset("u", nil, at: nil)]
        let result = PlaceSplitPolicy.evaluate(input(assets))
        #expect(unassigned(result) == ["u"])
        #expect(!groups(result).flatMap(\.members).contains("u"))
    }

    @Test func inputOrderDoesNotMatter() {
        var assets = (0..<6).map { asset("h\($0)", hanoi, at: Double($0)) } + (0..<4).map { asset("n\($0)", ninhBinh, at: 8 + Double($0)) }
        assets += [asset("x", nil, at: 7), asset("y", nil, at: 20), asset("s", saPa, at: 30)]
        let reference = PlaceSplitPolicy.evaluate(input(assets))
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            #expect(PlaceSplitPolicy.evaluate(input(assets.shuffled(using: &generator))) == reference)
        }
    }
}
