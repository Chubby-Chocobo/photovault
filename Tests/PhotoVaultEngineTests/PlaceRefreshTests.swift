import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// "Làm mới địa danh" keeps what is known while the cells are asked for again, and only what
/// really changed is written. Turning place names off takes the place off Drive.
@Suite struct PlaceRefreshTests {
    private func placeLife() async throws -> Harness {
        let h = try await Harness.organized()
        try await h.update {
            $0.viewByDeviceEnabled = false
            $0.viewFavoritesEnabled = false
            $0.viewByPlaceEnabled = true
            $0.sidecarJsonEnabled = true
            $0.sidecarXmpEnabled = false
        }
        try h.addDrive(scope: .full)
        await h.geocoder.seed(daLat, en: daLatEnglish, vi: daLatVietnamese)
        await h.add(h.snapshot("p0", daysAgo: 3, location: daLat), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        return h
    }

    private func writes(_ h: Harness) async -> Int {
        let log = await h.drive.operationLog
        return log.filter { $0 == .upload || $0 == .replace || $0 == .shortcut }.count
    }

    private func liveShortcutIds(_ h: Harness) async -> [String] {
        await h.drive.shortcuts.filter { !$0.trashed }.map(\.id).sorted()
    }

    @Test func refreshingWithUnchangedAnswersWritesNothingAndKeepsThePlaceView() async throws {
        let h = try await placeLife()
        let shortcuts = await liveShortcutIds(h)
        let description = await h.backupFile(h.drive)?.description
        #expect(!shortcuts.isEmpty && description?.contains("Place:") == true)
        let requestsBefore = await h.geocoder.requestCount
        let writesBefore = await writes(h)

        // The answers are on their way: until they arrive nothing is renamed or removed.
        await h.geocoder.setFailure(FakeGeocoder.Failure())
        try await h.coordinator.refreshPlaceNames()
        await h.run()
        #expect(await liveShortcutIds(h) == shortcuts)
        #expect(await h.backupFile(h.drive)?.description == description)
        #expect(await h.geocoder.requestCount > requestsBefore, "the cells are asked for again")

        await h.geocoder.setFailure(nil)
        await h.settle()
        #expect(await h.geocoder.requestCount >= requestsBefore + 2)
        #expect(await liveShortcutIds(h) == shortcuts, "same answers: the same shortcuts")
        #expect(await h.backupFile(h.drive)?.description == description)
        #expect(await writes(h) == writesBefore, "no sidecar, description or shortcut was written again")
    }

    @Test func aChangedAnswerUpdatesOnlyWhatFollowsFromIt() async throws {
        let h = try await placeLife()
        let corrected = GeoPlace(isoCountryCode: "VN", country: "Việt Nam", administrativeArea: "Lâm Đồng", locality: "Xuân Hương")
        await h.geocoder.seed(daLat, en: daLatEnglish, vi: corrected)
        try await h.coordinator.refreshPlaceNames()
        await h.settle()
        #expect(await h.backupFile(h.drive)?.description?.contains("Xuân Hương") == true)
    }

    @Test func descriptionWithNothingLeftClearsTheOldPlace() async throws {
        let h = try await placeLife()
        // No camera or lens is known: the place is the only part of the description.
        try h.write { db in try db.execute(sql: "UPDATE asset SET camera_make = NULL, camera_model = NULL, lens_model = NULL") }
        try await h.coordinator.refreshOrganization()
        await h.settle()
        #expect(await h.backupFile(h.drive)?.description == "Place: Đà Lạt, Lâm Đồng, Việt Nam")

        try await h.update { $0.placeNamesEnabled = false }
        try await h.coordinator.refreshOrganization()
        await h.settle()
        #expect(await h.backupFile(h.drive)?.description == "", "the old Place: is taken off")
    }
}
