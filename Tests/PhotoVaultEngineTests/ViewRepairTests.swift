import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// "Dựng lại view" brings back what the owner removed, and a stuck trash does not stop the cycle.
@Suite struct ViewRepairTests {
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

    private func live(_ h: Harness) async -> [FakeDestination.Item] {
        await h.drive.shortcuts.filter { !$0.trashed }
    }

    @Test func rebuildRestoresDeletedFoldersAndShortcutsWithoutAnIntegrityCheck() async throws {
        let h = try await favoritesLife()
        let dayFolder = try #require(await h.drive.folders.first { $0.appProperties[AppPropertyKey.logical]?.hasPrefix("view/favorites/") == true })
        await h.drive.externallyDelete(dayFolder.id)
        for shortcut in await h.drive.shortcuts { await h.drive.externallyDelete(shortcut.id) }
        try await h.coordinator.rebuildViews()
        await h.settle()
        #expect(await live(h).count == 1)
        #expect(await h.drive.folders.filter { $0.appProperties[AppPropertyKey.logical]?.hasPrefix("view/favorites/") == true }.count == 1)
        #expect(await h.drive.contractViolations.isEmpty)
    }

    @Test func rebuildRestoresASingleDeletedShortcutInAnExistingFolder() async throws {
        let h = try await favoritesLife()
        let shortcut = try #require(await live(h).first)
        await h.drive.externallyDelete(shortcut.id)
        try await h.coordinator.rebuildViews()
        await h.settle()
        let restored = await live(h)
        #expect(restored.count == 1 && restored[0].id != shortcut.id)
        #expect(try h.shortcutRows(.googleDrive).filter { $0.state == .done }.count == 1)
    }

    @Test func rebuildMakesAFailedShortcutAgainAndKeepsShortcutsThatStillExist() async throws {
        let h = try await favoritesLife()
        let shortcut = try #require(await live(h).first)
        await h.drive.externallyDelete(shortcut.id)
        try h.write { db in try db.execute(sql: "UPDATE shortcut SET state = 'failed', attempts = 9") }
        try await h.coordinator.rebuildViews()
        await h.settle()
        #expect(await live(h).count == 1)

        // A failed row whose shortcut still exists is kept, not duplicated.
        let kept = try #require(await live(h).first)
        try h.write { db in try db.execute(sql: "UPDATE shortcut SET state = 'failed', attempts = 9") }
        try await h.coordinator.rebuildViews()
        await h.settle()
        #expect(await live(h).map(\.id) == [kept.id])
        #expect(try h.shortcutRows(.googleDrive).allSatisfy { $0.state == .done && $0.attempts == 0 })
    }

    @Test func aTrashThatKeepsFailingDoesNotEndTheCycle() async throws {
        let h = try await favoritesLife()
        try h.write { db in try db.execute(sql: "UPDATE shortcut SET state = 'trashPending'") }
        await h.drive.failNext(.shortcut, with: .itemRejected(reason: "refused"), times: 1)
        let outcome = await h.run()
        guard case .completed = outcome else {
            Issue.record("the cycle ended with \(outcome)")
            return
        }
        // The pass stopped on the failure; the next round finishes the trash.
        await h.settle()
        #expect(try h.shortcutRows(.googleDrive).allSatisfy { $0.state != .trashPending })
    }

    @Test func aTrashTheDestinationRefusesSwitchesViewsOffInsteadOfFailingEveryCycle() async throws {
        let h = try await favoritesLife()
        try h.write { db in try db.execute(sql: "UPDATE shortcut SET state = 'trashPending'") }
        await h.drive.failNext(.shortcut, with: .viewsNotPermitted, times: 1)
        let outcome = await h.run()
        guard case .completed = outcome else {
            Issue.record("the cycle ended with \(outcome)")
            return
        }
        #expect(try h.read { db in try ViewStage.isDisabled(db, .googleDrive) })
    }
}
