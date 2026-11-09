import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// The archive day used by the organization tests: three days before the test clock, so the day
/// has been over for far longer than the six hours place naming waits.
let organizationDay = ArchiveDay(date: Date(timeIntervalSince1970: 1_793_000_000 - 3 * 86_400), timeZone: utc)

extension Harness {
    static func organized(_ tuning: ((inout EngineTuning) -> Void)? = nil) async throws -> Harness {
        try await Harness(organization: true, tuning: tuning)
    }

    /// Switches the organization features off again (day-folder tests that only look at files).
    func withoutSidecarsAndViews() async throws {
        try await update {
            $0.sidecarJsonEnabled = false
            $0.sidecarXmpEnabled = false
            $0.viewByDeviceEnabled = false
            $0.viewByPlaceEnabled = false
            $0.viewFavoritesEnabled = false
        }
    }

    @discardableResult
    func addCameraAssets(_ count: Int, prefix: String = "c", daysAgo: Double = 3, recordChange: Bool = true, location: GeoPoint? = nil) async -> [String] {
        var ids: [String] = []
        for index in 0..<count {
            let id = "\(prefix)\(index)"
            ids.append(id)
            await add(snapshot(id, daysAgo: daysAgo, location: location), recordChange: recordChange)
        }
        return ids
    }

    /// Display paths of the backup files (no sidecars) at `destination`.
    func backupPaths(_ destination: FakeDestination) async -> [String] {
        var paths: [String] = []
        for file in await destination.files where !file.name.hasSuffix(".json") && !file.name.hasSuffix(".xmp") {
            paths.append(await destination.path(of: file.id))
        }
        return paths.sorted()
    }

    func sidecarItems(_ destination: FakeDestination) async -> [FakeDestination.Item] {
        await destination.files.filter { $0.name.hasSuffix(".json") || $0.name.hasSuffix(".xmp") }
    }

    func moveJobs(_ state: MoveJobState, destination: DestinationID) throws -> [MoveJob] {
        try read { db in try MoveJobRepository.fetch(db, destinationId: destination, state: state) }
    }

    func shortcutRecords(_ destination: DestinationID, state: ShortcutState) throws -> [ShortcutRecord] {
        try read { db in try ShortcutRepository.fetch(db, destinationId: destination, state: state) }
    }

    /// Runs cycles, advancing the clock between them, until nothing is left to do.
    func settle(rounds: Int = 4) async {
        for _ in 0..<rounds {
            await run()
            clock.advance(by: 60)
        }
    }
}

let daLat = GeoPoint(latitude: 11.9404, longitude: 108.4583)
let hanoi = GeoPoint(latitude: 21.0285, longitude: 105.8542)
let tokyo = GeoPoint(latitude: 35.6762, longitude: 139.6503)

extension FakeGeocoder {
    /// Answers for `en` and for the cell's second locale (`PlaceNameRule.secondLocale`); `local` defaults to the English answer.
    func seed(_ point: GeoPoint, en: GeoPlace, local: GeoPlace? = nil) async {
        let cell = GeoCell(point)
        set(en, for: cell, locale: "en")
        if let locale = PlaceNameRule.secondLocale(country: en.isoCountryCode ?? "") {
            set(local ?? en, for: cell, locale: locale)
        }
    }
}

let daLatEnglish = GeoPlace(isoCountryCode: "VN", country: "Vietnam", administrativeArea: "Lam Dong", locality: "Da Lat")
let daLatVietnamese = GeoPlace(isoCountryCode: "VN", country: "Việt Nam", administrativeArea: "Lâm Đồng", locality: "Đà Lạt")
let hanoiEnglish = GeoPlace(isoCountryCode: "VN", country: "Vietnam", administrativeArea: "Hanoi", locality: "Hanoi")
let hanoiVietnamese = GeoPlace(isoCountryCode: "VN", country: "Việt Nam", administrativeArea: "Hà Nội", locality: "Hà Nội")
let tokyoEnglish = GeoPlace(isoCountryCode: "JP", country: "Japan", administrativeArea: "Tokyo", locality: "Shinjuku")
let tokyoNative = GeoPlace(isoCountryCode: "JP", country: "日本", administrativeArea: "東京都", locality: "新宿区")

extension Harness {
    /// Logical path of the camera day folder for photos taken `daysAgo` days before the test clock.
    func cameraDayPath(daysAgo: Double) -> String {
        "camera/\(ArchiveDay(date: clock.now.addingTimeInterval(-daysAgo * 86_400), timeZone: utc))"
    }
}
