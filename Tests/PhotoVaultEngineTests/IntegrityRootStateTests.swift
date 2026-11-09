import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// An integrity check never judges what sits under a root or folder the owner can still restore,
/// and it only tidies the app's own shortcuts of the current root.
@Suite struct IntegrityRootStateTests {
    private func driveLife(organized: Bool = false) async throws -> Harness {
        let h = organized ? try await Harness.organized() : try await Harness()
        try h.addDrive(scope: .full)
        for index in 0..<3 {
            var snapshot = h.snapshot("p\(index)", daysAgo: Double(index + 1))
            snapshot.isFavorite = index == 0
            await h.add(snapshot, recordChange: false)
        }
        try await h.baseline(.googleDrive)
        await h.settle(rounds: organized ? 6 : 4)
        return h
    }

    private func markAllMissing(_ h: Harness) throws {
        try h.write { db in try db.execute(sql: "UPDATE upload_job SET state = 'missingRemote'") }
    }

    @Test func aTrashedRootIsSkippedAndNothingIsMarkedMissing() async throws {
        let h = try await driveLife()
        await h.drive.externallyTrash("root")
        let report = try await h.coordinator.runIntegrityCheck(.googleDrive)
        #expect(report.skippedDestinations == [.googleDrive])
        #expect(report.missing == 0 && report.checked == 0)
        #expect(try h.jobs(.missingRemote).isEmpty)
        #expect(try h.jobs().allSatisfy { $0.state == .done })
        #expect(await h.coordinator.pendingOwnerDecisions().allSatisfy { if case .integrityMissing = $0 { false } else { true } })
    }

    @Test func aDestinationPausedForItsRootIsSkippedToo() async throws {
        let h = try await driveLife()
        await h.drive.externallyTrash("root")
        await h.run()
        #expect(try h.destinationRecord(.googleDrive).status == .paused(.rootTrashed))
        let report = try await h.coordinator.runIntegrityCheck(nil)
        #expect(report.skippedDestinations == [.googleDrive])
        #expect(try h.jobs(.missingRemote).isEmpty)
    }

    @Test func aMissingRootIsSkipped() async throws {
        let h = try await driveLife()
        await h.drive.externallyDelete("root")
        let report = try await h.coordinator.runIntegrityCheck(.googleDrive)
        #expect(report.skippedDestinations == [.googleDrive])
        #expect(try h.jobs(.missingRemote).isEmpty)
    }

    @Test func filesUnderATrashedFolderAreNotCountedAsMissing() async throws {
        let h = try await driveLife()
        let month = try #require(await h.drive.folders.first { $0.appProperties[AppPropertyKey.logical] == h.cameraDayPath(daysAgo: 1) })
        await h.drive.externallyTrash(month.id)
        let report = try await h.coordinator.runIntegrityCheck(.googleDrive)
        #expect(report.missing == 0)
        #expect(try h.jobs().allSatisfy { $0.state == .done })
    }

    @Test func aFileTheOwnerTrashedInAHealthyFolderIsStillMissing() async throws {
        let h = try await driveLife()
        let file = try #require(await h.drive.files.first)
        await h.drive.externallyTrash(file.id)
        let report = try await h.coordinator.runIntegrityCheck(.googleDrive)
        #expect(report.missing == 1)
    }

    @Test func restoringTheRootHealsMissingFilesWithoutWaitingForTheNextCheck() async throws {
        let h = try await driveLife()
        await h.drive.externallyTrash("root")
        await h.run()
        try markAllMissing(h)
        _ = try await h.drive.untrash(remoteId: "root")
        try await h.coordinator.resolveRootProblem(.googleDrive, choice: .ownerRestored)
        #expect(try h.jobs(.missingRemote).isEmpty)
        #expect(try h.jobs().allSatisfy { $0.state == .done })
        await h.settle()
        #expect(await h.drive.files.count == 3, "nothing was uploaded again")
    }

    @Test func untrashingTheAppItemsHealsMissingFiles() async throws {
        let h = try await driveLife()
        let month = try #require(await h.drive.folders.first { $0.appProperties[AppPropertyKey.logical] == h.cameraDayPath(daysAgo: 1) })
        await h.drive.externallyTrash(month.id)
        try markAllMissing(h)
        try await h.coordinator.untrashAppItems(.googleDrive)
        #expect(try h.jobs(.missingRemote).isEmpty)
    }

    @Test func untrashingRestoresOnlyFoldersOfTheCurrentRoot() async throws {
        let h = try await driveLife()
        await h.drive.setListsWholeAccount(true)
        let schema = [AppPropertyKey.schema: AppPropertyCodec.schemaVersion]
        await h.drive.put(.init(id: "old-root", name: "Old", parentId: "", kind: .folder, appProperties: schema, trashed: true))
        await h.drive.put(.init(id: "old-month", name: "01", parentId: "old-root", kind: .folder, appProperties: schema, trashed: true))
        let month = try #require(await h.drive.folders.first { $0.appProperties[AppPropertyKey.logical] == h.cameraDayPath(daysAgo: 1) })
        await h.drive.externallyTrash(month.id)
        try await h.coordinator.untrashAppItems(.googleDrive)
        #expect(await h.drive.items[month.id]?.trashed == false)
        #expect(await h.drive.items["old-root"]?.trashed == true)
        #expect(await h.drive.items["old-month"]?.trashed == true)
    }

    @Test func healingLeavesFilesThatAreReallyGoneMissing() async throws {
        let h = try await driveLife()
        await h.drive.externallyTrash("root")
        await h.run()
        try markAllMissing(h)
        let gone = try #require(await h.drive.files.first)
        await h.drive.externallyDelete(gone.id)
        _ = try await h.drive.untrash(remoteId: "root")
        try await h.coordinator.resolveRootProblem(.googleDrive, choice: .ownerRestored)
        #expect(try h.jobs(.missingRemote).count == 1)
        #expect(try h.jobs(.missingRemote).first?.remoteId == gone.id)
    }

    // MARK: Strays

    @Test func shortcutsOfAnotherRootInTheSameAccountAreLeftAlone() async throws {
        let h = try await driveLife(organized: true)
        await h.drive.setListsWholeAccount(true)
        let ownShortcuts = await h.drive.shortcuts.count
        #expect(ownShortcuts > 0)
        await h.drive.put(FakeDestination.Item(
            id: "other-root", name: "Other Mac", parentId: "", kind: .folder, content: nil,
            appProperties: [AppPropertyKey.root: "1", AppPropertyKey.schema: "1"], description: nil, targetId: nil, trashed: false))
        await h.drive.put(FakeDestination.Item(
            id: "other-view", name: "By device", parentId: "other-root", kind: .folder, content: nil,
            appProperties: [AppPropertyKey.schema: "1"], description: nil, targetId: nil, trashed: false))
        let target = try #require(await h.drive.files.first)
        await h.drive.put(FakeDestination.Item(
            id: "other-shortcut", name: "x", parentId: "other-view", kind: .shortcut, content: nil,
            appProperties: [AppPropertyKey.schema: "1", AppPropertyKey.view: "favorites"], description: nil, targetId: target.id, trashed: false))

        let report = try await h.coordinator.runIntegrityCheck(.googleDrive)
        #expect(report.shortcutsTrashed == 0)
        #expect(await h.drive.items["other-shortcut"]?.trashed == false)
        #expect(await h.drive.shortcuts.filter { !$0.trashed }.count == ownShortcuts + 1)
        #expect(await h.drive.contractViolations.isEmpty)
    }
}
