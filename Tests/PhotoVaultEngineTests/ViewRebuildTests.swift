import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// "Dựng lại view" forgets a view folder only when Drive says it is gone.
@Suite struct ViewRebuildTests {
    private func favoritesLife() async throws -> Harness {
        let h = try await Harness.organized()
        try await h.update { $0.viewByDeviceEnabled = false; $0.viewByPlaceEnabled = false }
        try h.addDrive(scope: .full)
        var photo = h.snapshot("f1", daysAgo: 3)
        photo.isFavorite = true
        await h.add(photo, recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        return h
    }

    private func favoriteDayFolders(_ h: Harness) async -> [FakeDestination.Item] {
        await h.drive.folders.filter { $0.appProperties[AppPropertyKey.logical]?.hasPrefix("view/favorites/") == true }
    }

    @Test func aFailedProbeDuringTheRebuildCreatesNoSecondFolderAndTheRebuildFinishesLater() async throws {
        let h = try await favoritesLife()
        #expect(await favoriteDayFolders(h).count == 1)
        let shortcutsBefore = await h.drive.shortcuts.filter { !$0.trashed }.count
        try await h.coordinator.rebuildViews()
        await h.drive.failNext(.probe, with: .offline)
        await h.run()
        #expect(await favoriteDayFolders(h).count == 1, "the folder that still exists is not duplicated")
        #expect(try h.read { db in try KeyValueRepository.int(db, "rebuild:view") } == 1, "the rebuild waits")

        // Drive answers again: the rebuild completes and nothing is doubled.
        await h.settle()
        #expect(await favoriteDayFolders(h).count == 1)
        #expect(await h.drive.shortcuts.filter { !$0.trashed }.count == shortcutsBefore)
        #expect(try h.read { db in try KeyValueRepository.int(db, "rebuild:view") } == nil, "the rebuild is finished")
    }

    @Test func aFolderDriveSaysIsGoneIsCreatedAgainByTheRebuild() async throws {
        let h = try await favoritesLife()
        let dayFolder = try #require(await favoriteDayFolders(h).first)
        // Deleting a folder takes what is in it along; the integrity check notes that the owner removed it.
        await h.drive.externallyDelete(dayFolder.id)
        for shortcut in await h.drive.shortcuts { await h.drive.externallyDelete(shortcut.id) }
        _ = try await h.coordinator.runIntegrityCheck(.googleDrive)
        try await h.coordinator.rebuildViews()
        await h.settle()
        let folders = await favoriteDayFolders(h)
        #expect(folders.count == 1 && folders[0].id != dayFolder.id)
        #expect(await h.drive.shortcuts.filter { !$0.trashed }.count == 1)
    }
}
