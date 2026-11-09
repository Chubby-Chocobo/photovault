import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// T28, T36 and the place-naming settings (FR-80..85, spec 8.11).
@Suite struct PlaceNameTests {
    private func harness() async throws -> Harness {
        let h = try await Harness.organized()
        try await h.update {
            $0.viewByDeviceEnabled = false
            $0.viewByPlaceEnabled = false
            $0.viewFavoritesEnabled = false
            $0.sidecarJsonEnabled = false
            $0.sidecarXmpEnabled = false
        }
        try h.addDrive(scope: .full)
        try h.addNAS(scope: .full)
        return h
    }

    private func dayFolders(_ destination: FakeDestination) async -> [String] {
        await destination.folders.map(\.name).filter { $0.hasPrefix(organizationDay.description) }
    }

    @Test func t28DaLatDayIsNamedAtEveryDestination() async throws {
        let h = try await harness()
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        // iPhone photos with GPS plus a RAW without GPS: 12 camera assets, only the iPhone ones count for the place.
        for index in 0..<10 { await h.add(h.snapshot("p\(index)", daysAgo: 3, location: daLat), recordChange: false) }
        await h.add(h.snapshot("raw1", daysAgo: 3, raw: true), recordChange: false)
        await h.add(h.snapshot("raw2", daysAgo: 3, raw: true), recordChange: false)
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle()
        let stat = try #require(try h.dayStat(organizationDay))
        #expect(stat.promoted && stat.placeState == .named)
        #expect(stat.placeName == "Đà Lạt")
        #expect(stat.placeKey == "VN|Lam Dong")
        let expected = "\(organizationDay) Đà Lạt"
        #expect(await dayFolders(h.drive) == [expected])
        #expect(await dayFolders(h.nas) == [expected])
        #expect(await h.backupPaths(h.drive).allSatisfy { $0.hasPrefix("Camera Uploads/\(expected)/") })
        #expect(await h.backupPaths(h.nas).count == 12)
        #expect(try h.moveJobs(.pending, destination: .googleDrive).isEmpty)
        // The folder path in the database stays logical; only the display name changed.
        let folder = try h.read { db in try RemoteFolderRepository.fetch(db, destinationId: .googleDrive, logicalPath: "camera/\(organizationDay)") }
        #expect(folder?.displayName == expected)
        // Only the two cell requests (en + vi) were needed for 12 photos in one cell.
        #expect(await h.geocoder.requestCount == 2)
    }

    @Test func t28TwoProvincesGiveNoNameAndAnImportDropsAnExistingName() async throws {
        let h = try await harness()
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        await h.geocoder.seed(hanoi, en: hanoiEnglish, local: hanoiVietnamese)
        for index in 0..<11 { await h.add(h.snapshot("p\(index)", daysAgo: 3, location: daLat), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.settle()
        #expect(await dayFolders(h.drive) == ["\(organizationDay) Đà Lạt"])

        await h.add(h.snapshot("far", daysAgo: 3, location: hanoi))
        await h.settle()
        #expect(try h.dayStat(organizationDay)?.placeState == .unnamed)
        #expect(await dayFolders(h.drive) == [organizationDay.description], "the place was dropped from the folder name")
        #expect(await h.backupPaths(h.drive).allSatisfy { $0.hasPrefix("Camera Uploads/\(organizationDay)/") })
    }

    @Test func aDayThatHasNotEndedForSixHoursIsNotNamedYet() async throws {
        let h = try await harness()
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        for index in 0..<11 { await h.add(h.snapshot("p\(index)", daysAgo: 0.05, location: daLat), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.settle()
        let today = ArchiveDay(date: h.clock.now.addingTimeInterval(-0.05 * 86_400), timeZone: utc)
        #expect(try h.dayStat(today)?.placeState == .pending)
        h.clock.advance(by: 2 * 86_400)
        await h.settle()
        #expect(try h.dayStat(today)?.placeState == .named)
    }

    @Test func t36GeocodingStaysUnderTwentyRequestsPerMinuteAndNewestCellsGoFirst() async throws {
        let h = try await harness()
        // An old day with place names, then 40 newer cells: the newest cells are asked first.
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        for index in 0..<11 { await h.add(h.snapshot("d\(index)", daysAgo: 100, location: daLat), recordChange: false) }
        for index in 0..<40 {
            let point = GeoPoint(latitude: 10 + Double(index) * 0.05, longitude: 100 + Double(index) * 0.05)
            await h.add(h.snapshot("o\(index)", daysAgo: 1 + Double(index), location: point), recordChange: false)
        }
        try await h.baseline(.googleDrive)
        await h.run()
        var requests = await h.geocoder.requests
        #expect(requests.count == GeocodeScheduler.requestsPerMinute)
        #expect(!requests.contains { $0.cell == GeoCell(daLat) }, "the oldest cell waits for the newer ones")
        let newestFirst = requests.map(\.cell)
        let expectedOrder = (0..<40).map { GeoCell(GeoPoint(latitude: 10 + Double($0) * 0.05, longitude: 100 + Double($0) * 0.05)) }
        #expect(Array(newestFirst.prefix(3)) == Array(expectedOrder.prefix(3)), "unanswered cells need only the english request")

        await h.run()
        #expect(await h.geocoder.requestCount == GeocodeScheduler.requestsPerMinute, "no more within the same minute")
        h.clock.advance(by: 61)
        await h.run()
        requests = await h.geocoder.requests
        #expect(requests.count == 2 * GeocodeScheduler.requestsPerMinute)
        // Uploads were not held back by geocoding.
        #expect(try h.jobs(.pending).isEmpty)
    }

    @Test func geocodingErrorsBackOffInsteadOfRetryingImmediately() async throws {
        let h = try await harness()
        await h.geocoder.setFailure(FakeGeocoder.Failure())
        for index in 0..<11 { await h.add(h.snapshot("p\(index)", daysAgo: 3, location: daLat), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.run()
        #expect(await h.geocoder.requestCount == 1)
        await h.run()
        #expect(await h.geocoder.requestCount == 1, "still backing off")
        await h.geocoder.setFailure(nil)
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        h.clock.advance(by: 31 * 60)
        await h.settle()
        #expect(try h.dayStat(organizationDay)?.placeState == .named)
    }

    @Test func turningPlaceNamesOffSendsNothing() async throws {
        let h = try await harness()
        try await h.update { $0.placeNamesEnabled = false }
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        for index in 0..<11 { await h.add(h.snapshot("p\(index)", daysAgo: 3, location: daLat), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.settle()
        #expect(await h.geocoder.requestCount == 0)
        #expect(await dayFolders(h.drive) == [organizationDay.description])
    }

    @Test func foreignCountryNamesIncludeTheCountry() async throws {
        let h = try await harness()
        await h.geocoder.seed(tokyo, en: tokyoEnglish, local: tokyoNative)
        for index in 0..<11 { await h.add(h.snapshot("p\(index)", daysAgo: 3, location: tokyo), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.settle()
        #expect(await dayFolders(h.drive) == ["\(organizationDay) Shinjuku (新宿区), Japan"])
    }

    @Test func aJapaneseCellIsAskedAgainInJapaneseAndStoredAsLocal() async throws {
        let h = try await harness()
        await h.geocoder.seed(tokyo, en: tokyoEnglish, local: tokyoNative)
        await h.add(h.snapshot("p", daysAgo: 3, location: tokyo), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.run()
        let requests = await h.geocoder.requests
        #expect(requests.map(\.locale) == ["en", "ja"], "\(requests)")
        #expect(requests.allSatisfy { $0.cell == GeoCell(tokyo) })
        let cell = GeoCell(tokyo)
        let stored = try h.read { db in
            (try GeoCacheRepository.fetch(db, cell: cell, locale: "local")?.place, try GeoCacheRepository.fetch(db, cell: cell, locale: "ja"))
        }
        #expect(stored.0?.locality == "新宿区")
        #expect(stored.1 == nil, "kept under one key whatever the language")
    }

    @Test func aBritishCellMakesOnlyTheEnglishRequest() async throws {
        let h = try await harness()
        let london = GeoPoint(latitude: 51.5074, longitude: -0.1278)
        let uk = GeoPlace(isoCountryCode: "GB", country: "United Kingdom", administrativeArea: "England", locality: "London")
        await h.geocoder.seed(london, en: uk)
        for index in 0..<11 { await h.add(h.snapshot("p\(index)", daysAgo: 3, location: london), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.settle()
        #expect(await h.geocoder.requests.map(\.locale) == ["en"])
        let cell = GeoCell(london)
        let local = try h.read { db in try GeoCacheRepository.fetch(db, cell: cell, locale: "local")?.place }
        #expect(local?.locality == "London", "the English answer stands in for the second one")
        #expect(await dayFolders(h.drive) == ["\(organizationDay) London, United Kingdom"])
    }

    @Test func refreshingPlaceNamesClearsTheCacheAndRenames() async throws {
        let h = try await harness()
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        for index in 0..<11 { await h.add(h.snapshot("p\(index)", daysAgo: 3, location: daLat), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.settle()
        let corrected = GeoPlace(isoCountryCode: "VN", country: "Việt Nam", administrativeArea: "Lâm Đồng", locality: "Xuân Hương")
        await h.geocoder.seed(daLat, en: daLatEnglish, local: corrected)
        await h.run()
        #expect(await dayFolders(h.drive) == ["\(organizationDay) Đà Lạt"], "cached results are final")
        try await h.coordinator.refreshPlaceNames()
        await h.settle()
        #expect(await dayFolders(h.drive) == ["\(organizationDay) Xuân Hương"])
        #expect(await h.geocoder.requestCount == 4)
    }

    /// Apple answers a cell on the water with a country and no province (measured on Hạ Long bay).
    /// A boat trip must not switch the whole library to country names or cost the day its province.
    @Test func aBoatTripStillNamesTheDayAfterItsProvince() async throws {
        let h = try await harness()
        let quangNinh = GeoPoint(latitude: 20.95, longitude: 107.08)
        await h.geocoder.seed(quangNinh,
                              en: GeoPlace(isoCountryCode: "VN", country: "Vietnam", administrativeArea: "Quang Ninh"),
                              local: GeoPlace(isoCountryCode: "VN", country: "Việt Nam", administrativeArea: "Quảng Ninh"))
        await h.add(h.snapshot("port", daysAgo: 3, location: quangNinh), recordChange: false)
        // The water photos are newer, so they are geocoded first.
        for index in 0..<12 {
            let point = GeoPoint(latitude: 20.80 + Double(index) * 0.011, longitude: 107.18)
            await h.geocoder.seed(point, en: GeoPlace(isoCountryCode: "VN", country: "Vietnam"), local: GeoPlace(isoCountryCode: "VN", country: "Việt Nam"))
            await h.add(h.snapshot("bay\(index)", daysAgo: 2.99 - Double(index) * 0.001, location: point), recordChange: false)
        }
        try await h.baseline(.googleDrive)
        await h.settle()
        #expect(try h.dayStat(organizationDay)?.placeKey == "VN|Quang Ninh")
        #expect(await dayFolders(h.drive) == ["\(organizationDay) Quảng Ninh"])
    }

    @Test func missingProvinceFieldsDowngradeToTheCountryAndTellTheOwner() async throws {
        let h = try await harness()
        let countryOnly = GeoPlace(isoCountryCode: "VN", country: "Việt Nam")
        for index in 0..<11 {
            let point = GeoPoint(latitude: 11.9 + Double(index) * 0.05, longitude: 108.4)
            await h.geocoder.seed(point, en: GeoPlace(isoCountryCode: "VN", country: "Vietnam"), local: countryOnly)
            await h.add(h.snapshot("p\(index)", daysAgo: 3, location: point), recordChange: false)
        }
        try await h.baseline(.googleDrive)
        await h.settle()
        #expect(try h.dayStat(organizationDay)?.placeState == .named)
        // The country-only fallback names the day after the country, and country names are English.
        #expect(await dayFolders(h.drive) == ["\(organizationDay) Vietnam"])
        let notices = try h.read { db in try ActivityRepository.recent(db).filter { $0.kind == .notice } }
        #expect(notices.count == 1, "the owner is told once")
    }
}

extension FakeGeocoder {
    struct Failure: Error {}
}
