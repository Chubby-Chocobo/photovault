import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// The By lens view: opt-in, grouped by normalised lens name, kept for photos deleted from Photos.
@Suite struct ViewByLensTests {
    private func harness(lensOn: Bool = true) async throws -> Harness {
        let h = try await Harness.organized()
        try await h.update {
            $0.sidecarJsonEnabled = false
            $0.sidecarXmpEnabled = false
            $0.viewByDeviceEnabled = false
            $0.viewByPlaceEnabled = false
            $0.viewFavoritesEnabled = false
            $0.viewByLensEnabled = lensOn
        }
        try h.addDrive(scope: .full)
        return h
    }

    private func lensPaths(_ h: Harness) async -> [String] {
        var paths: [String] = []
        for item in await h.drive.shortcuts where !item.trashed {
            let path = await h.drive.path(of: item.id)
            if path.hasPrefix("By lens/") { paths.append(path) }
        }
        return paths.sorted()
    }

    @Test func shortcutsGoUnderTheLensFolderWhenEnabled() async throws {
        let h = try await harness()
        await h.add(h.snapshot("a1", daysAgo: 3), recordChange: false)
        await h.add(h.snapshot("sony1", daysAgo: 3), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        let paths = await lensPaths(h)
        #expect(paths.count == 2, "\(paths)")
        #expect(paths.contains { $0.hasPrefix("By lens/Wide/\(organizationDay)/") }, "\(paths)")
        #expect(paths.contains { $0.hasPrefix("By lens/FE 24-70/\(organizationDay)/") }, "\(paths)")
        let folder = try #require(await h.drive.folders.first { $0.name == "By lens" })
        #expect(folder.appProperties[AppPropertyKey.view] == "byLens")
        #expect(await h.drive.contractViolations.isEmpty)
    }

    @Test func aLensFolderKeepsItsFirstNameWhenAnotherSpellingArrives() async throws {
        let h = try await harness()
        await h.add(h.snapshot("sony1", daysAgo: 3), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        await h.add(h.snapshot("sonylow2", daysAgo: 3))
        await h.settle()
        await h.add(h.snapshot("sony3", daysAgo: 3))
        await h.settle()
        let paths = await lensPaths(h)
        #expect(paths.count == 3, "\(paths)")
        #expect(paths.allSatisfy { $0.hasPrefix("By lens/FE 24-70/") }, "\(paths)")
        #expect(await h.drive.operationLog.filter { $0 == .rename }.isEmpty, "no folder was renamed")
        #expect(try h.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_job WHERE op = 'renameFolder'") } == 0)
    }

    @Test func nothingIsCreatedWhileTheViewIsOff() async throws {
        let h = try await harness(lensOn: false)
        await h.add(h.snapshot("a1", daysAgo: 3), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        #expect(await lensPaths(h).isEmpty)
        #expect(await h.drive.folders.first { $0.name == "By lens" } == nil)
    }

    @Test func turningItOnBackfillsAndOffKeepsTheTree() async throws {
        let h = try await harness(lensOn: false)
        await h.add(h.snapshot("a1", daysAgo: 3), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        try await h.update { $0.viewByLensEnabled = true }
        try await h.coordinator.settingsChanged()
        await h.settle()
        #expect(await lensPaths(h).count == 1)

        try await h.update { $0.viewByLensEnabled = false }
        try await h.coordinator.settingsChanged()
        await h.settle()
        #expect(await lensPaths(h).count == 1, "off leaves the tree as it is")
    }

    @Test func rebuildBringsBackWhatTheOwnerDeleted() async throws {
        let h = try await harness()
        await h.add(h.snapshot("a1", daysAgo: 3), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        let shortcut = try #require(await h.drive.shortcuts.first)
        await h.drive.externallyTrash(shortcut.id)
        await h.run()
        await h.settle()
        #expect(await lensPaths(h).isEmpty)
        try await h.coordinator.rebuildViews()
        await h.settle()
        #expect(await lensPaths(h).count == 1)
    }

    @Test func aPhotoDeletedFromPhotosKeepsItsLensShortcut() async throws {
        let h = try await harness()
        let snapshot = h.snapshot("a1", daysAgo: 3)
        await h.add(snapshot, recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        let before = await lensPaths(h)
        #expect(before.count == 1)
        await h.fakePhotos.delete(localId: snapshot.localId)
        _ = await h.run()
        await h.settle()
        #expect(await lensPaths(h) == before)
    }
}
