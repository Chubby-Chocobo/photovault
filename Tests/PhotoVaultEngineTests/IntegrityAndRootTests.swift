import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// T20 integrity (FR-47), T40 trashed or deleted folders, root problems and the owner's retries.
@Suite struct IntegrityAndRootTests {
    private func driveLife(assets: Int = 3, organized: Bool = false) async throws -> Harness {
        let h = organized ? try await Harness.organized() : try await Harness()
        try h.addDrive(scope: .full)
        for index in 0..<assets {
            var snapshot = h.snapshot("p\(index)", daysAgo: Double(index + 1))
            snapshot.isFavorite = index == 0
            await h.add(snapshot, recordChange: false)
        }
        try await h.baseline(.googleDrive)
        await h.settle(rounds: organized ? 6 : 4)
        return h
    }

    private func monthFolder(_ h: Harness) async throws -> FakeDestination.Item {
        try #require(await h.drive.folders.first { $0.appProperties[AppPropertyKey.logical] == "camera/2026/10" })
    }

    // MARK: T20

    @Test func t20DeletedFilesAreCountedAndOnlyUploadedAgainAfterTheOwnerConfirms() async throws {
        let h = try await driveLife()
        let originals = await h.drive.files
        await h.drive.externallyDelete(originals[0].id)
        await h.drive.externallyDelete(originals[1].id)
        let uploads = await h.count(of: .upload, on: h.drive)

        let report = try await h.coordinator.runIntegrityCheck(.googleDrive)
        #expect(report.missing == 2 && report.checked == 3)
        #expect(report.missingByDestination[.googleDrive] == 2)
        #expect(try h.jobs(.missingRemote).count == 2)
        #expect(await h.coordinator.pendingOwnerDecisions() == [.integrityMissing(.googleDrive, count: 2)])
        #expect(await h.coordinator.currentSnapshot().missingRemote == 2)

        await h.settle()
        #expect(await h.count(of: .upload, on: h.drive) == uploads, "nothing is uploaded before the owner confirms")

        try await h.coordinator.confirmReupload(.googleDrive)
        await h.settle()
        #expect(await h.drive.files.count == 3, "the missing files are back, no duplicate of the surviving one")
        #expect(Set(await h.drive.files.map(\.name)).count == 3)
        #expect(try h.jobs().allSatisfy { $0.state == .done })
        #expect(await h.coordinator.pendingOwnerDecisions().isEmpty)
        #expect(await h.drive.contractViolations.isEmpty)
    }

    @Test func integrityKeepsShortcutsTheOwnerRemovedAndTrashesOnlyStrayShortcuts() async throws {
        let h = try await driveLife(assets: 3, organized: true)
        let filesBefore = await h.drive.files.map(\.id).sorted()
        let shortcuts = await h.drive.shortcuts
        #expect(shortcuts.count >= 3)
        let ownerRemoved = shortcuts[0]
        await h.drive.externallyDelete(ownerRemoved.id)
        let stray = shortcuts[1]
        try h.write { db in try db.execute(sql: "DELETE FROM shortcut WHERE shortcut_id = ?", arguments: [stray.id]) }

        let report = try await h.coordinator.runIntegrityCheck(.googleDrive)
        #expect(report.shortcutsRemoved == 1 && report.shortcutsTrashed == 1)
        #expect(report.missing == 0)
        #expect(try h.shortcutRows(.googleDrive).first { $0.shortcutId == ownerRemoved.id }?.state == .userRemoved)
        #expect(await h.drive.items[stray.id]?.trashed == true)
        #expect(await h.drive.files.map(\.id).sorted() == filesBefore, "files are never touched")
        #expect(await h.drive.contractViolations.isEmpty)
        await h.settle()
        #expect(await h.drive.items[ownerRemoved.id] == nil, "a shortcut the owner deleted is not made again")
        let live = await h.drive.shortcuts.filter { !$0.trashed }.count
        #expect(live == shortcuts.count - 2, "the owner's removal stands and the stray one is gone")
    }

    @Test func theCycleChecksIntegrityEverySevenDays() async throws {
        let h = try await driveLife()
        await h.drive.externallyDelete(try #require(await h.drive.files.first).id)
        await h.settle()
        #expect(try h.jobs(.missingRemote).isEmpty, "not checked yet")
        h.clock.advance(by: 8 * 24 * 3600)
        await h.run()
        #expect(try h.jobs(.missingRemote).count == 1)
    }

    @Test(arguments: [(1, 2.0, true), (30, 8.0, false), (30, 31.0, true)])
    func theIntervalComesFromTheSettingInDays(_ days: Int, _ elapsed: Double, _ due: Bool) async throws {
        let h = try await driveLife()
        try await h.update { $0.integrityCheckIntervalDays = days }
        await h.drive.externallyDelete(try #require(await h.drive.files.first).id)
        await h.settle()
        h.clock.advance(by: elapsed * 24 * 3600)
        await h.run()
        #expect(try h.jobs(.missingRemote).count == (due ? 1 : 0))
    }

    // MARK: T40

    @Test func t40ATrashedMonthFolderIsFoundAtTheNextWriteAndUntrashingRestoresIt() async throws {
        let h = try await driveLife(assets: 2)
        let month = try await monthFolder(h)
        await h.drive.externallyTrash(month.id)
        await h.add(h.snapshot("late", daysAgo: 1), recordChange: true)
        await h.run()
        #expect(try h.destinationRecord(.googleDrive).status == .paused(.folderTrashed))
        #expect(await h.coordinator.pendingOwnerDecisions().contains(.folderTrashed(.googleDrive)))
        let uploads = await h.count(of: .upload, on: h.drive)
        await h.settle()
        #expect(await h.count(of: .upload, on: h.drive) == uploads, "the destination stays paused: no attempt every cycle")
        #expect(try h.destinationRecord(.googleDrive).status == .paused(.folderTrashed))

        try await h.coordinator.untrashAppItems(.googleDrive)
        #expect(await h.drive.items[month.id]?.trashed == false)
        #expect(try h.destinationRecord(.googleDrive).status == .active)
        await h.settle()
        #expect(await h.drive.files.count == 3)
        #expect(await h.drive.folders.filter { $0.name == "10" }.count == 1, "the same folder, not a second one")
        #expect(await h.coordinator.pendingOwnerDecisions().isEmpty)
    }

    @Test func aFolderThatAnswersNotFoundIsRecreatedAndItsFilesAreMarkedMissing() async throws {
        let h = try await driveLife(assets: 2)
        let month = try await monthFolder(h)
        await h.drive.externallyDelete(month.id)
        await h.add(h.snapshot("late", daysAgo: 1), recordChange: true)
        await h.settle()
        #expect(try h.jobs(.missingRemote).count == 2, "the files that were in the folder")
        #expect(try h.jobs(.done).count == 1, "the new photo went into the recreated folder")
        let recreated = await h.drive.folders.filter { $0.appProperties[AppPropertyKey.logical] == "camera/2026/10" }
        #expect(recreated.count == 1 && recreated[0].id != month.id)
        #expect(try h.activity().contains { $0.kind == .missingFile })
        #expect(await h.coordinator.pendingOwnerDecisions().contains(.integrityMissing(.googleDrive, count: 2)))
    }

    // MARK: Root problems

    private func controllableLife() async throws -> (Harness, ControllableDrive) {
        let h = try await Harness()
        let wrapper = ControllableDrive(h.drive)
        h.overrides = [wrapper]
        try await h.restart()
        try h.addDrive(scope: .full)
        for index in 0..<2 { await h.add(h.snapshot("r\(index)", daysAgo: Double(index + 1)), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.settle()
        return (h, wrapper)
    }

    private func rootCount(_ h: Harness) async -> Int {
        await h.drive.items.values.filter { $0.appProperties[AppPropertyKey.root] == "1" }.count
    }

    @Test func aTrashedRootPausesTheDestinationAndIsNeverRecreatedByTheEngine() async throws {
        let (h, _) = try await controllableLife()
        let roots = await rootCount(h)
        await h.drive.externallyTrash("root")
        await h.add(h.snapshot("after", daysAgo: 1), recordChange: true)
        await h.settle()
        #expect(try h.destinationRecord(.googleDrive).status == .paused(.rootTrashed))
        #expect(await h.coordinator.pendingOwnerDecisions().contains(.rootTrashed(.googleDrive)))
        #expect(await rootCount(h) == roots, "no root was created")
        #expect(await h.drive.files.count == 2)

        await #expect(throws: RootProblemError.stillTrashed) {
            try await h.coordinator.resolveRootProblem(.googleDrive, choice: .ownerRestored)
        }
        _ = try await h.drive.untrash(remoteId: "root")
        try await h.coordinator.resolveRootProblem(.googleDrive, choice: .ownerRestored)
        #expect(try h.destinationRecord(.googleDrive).status == .active)
        await h.settle()
        #expect(await h.drive.files.count == 3)
        await #expect(throws: RootProblemError.notRootProblem) {
            try await h.coordinator.resolveRootProblem(.googleDrive, choice: .ownerRestored)
        }
    }

    @Test func untrashingTheRootHelpsToo() async throws {
        let (h, _) = try await controllableLife()
        await h.drive.externallyTrash("root")
        await h.run()
        #expect(try h.destinationRecord(.googleDrive).status == .paused(.rootTrashed))
        try await h.coordinator.untrashAppItems(.googleDrive)
        #expect(await h.drive.items["root"]?.trashed == false)
        await h.run()
        #expect(try h.destinationRecord(.googleDrive).status == .active)
    }

    @Test func uploadingToANewRootStartsOverWithoutTouchingTheOldOne() async throws {
        let (h, wrapper) = try await controllableLife()
        let oldFiles = await h.drive.files.map(\.id).sorted()
        await h.drive.externallyDelete("root")
        await h.run()
        #expect(try h.destinationRecord(.googleDrive).status == .paused(.rootMissing))
        #expect(await h.coordinator.pendingOwnerDecisions().contains(.rootMissing(.googleDrive)))

        try await h.coordinator.resolveRootProblem(.googleDrive, choice: .uploadToNewRoot(name: "Backup 2"))
        let record = try h.destinationRecord(.googleDrive)
        let newRoot = try #require(record.config.driveRootId)
        #expect(newRoot != "root" && record.status == .active && !record.recoveryRequired)
        let item = try #require(await h.drive.items[newRoot])
        #expect(item.name == "Backup 2" && item.appProperties[AppPropertyKey.root] == "1")
        #expect(item.appProperties[AppPropertyKey.archiveTimezone] == utc.identifier)
        wrapper.activeRoot = newRoot
        await h.settle()
        #expect(try h.jobs(.done).count == 2, "everything is queued again and delivered")
        let fresh = await h.drive.files.filter { !oldFiles.contains($0.id) }
        #expect(fresh.count == 2)
        for file in fresh {
            var top = file
            while top.parentId != newRoot, let parent = await h.drive.items[top.parentId] { top = parent }
            #expect(top.parentId == newRoot)
        }
        #expect(await h.drive.files.filter { oldFiles.contains($0.id) }.count == 2, "the old files were not touched")
    }

    // MARK: Retries

    private func seedJob(_ h: Harness, _ id: String, state: JobState, _ change: (inout UploadJob) -> Void = { _ in }) throws {
        try h.seedStaged(id, job: (.googleDrive, state))
        try h.write { db in
            var job = try #require(try JobRepository.fetch(db, identity: JobIdentity(destinationId: .googleDrive, assetKey: .local(id), resType: .photo)))
            change(&job)
            try JobRepository.save(db, &job)
        }
    }

    @Test func deferredJobsComeBackAfterADayOrWhenTheOwnerAsks() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        let now = h.clock.now
        try seedJob(h, "auto", state: .deferred) {
            $0.stateReason = .uploadFailures
            $0.deferredSince = now
            $0.nextAttemptAt = now.addingTimeInterval(24 * 3600)
            $0.attempts = 9
        }
        try seedJob(h, "manual", state: .deferred) {
            $0.stateReason = .uploadFailures
            $0.deferredSince = now
            $0.nextAttemptAt = now.addingTimeInterval(24 * 3600)
            $0.attempts = 9
        }
        await h.run()
        #expect(try h.jobs(.deferred).count == 2, "not yet")
        try await h.coordinator.retryDeferred(.googleDrive)
        #expect(try h.jobs(.deferred).isEmpty && (try h.jobs(.pending)).count == 2)
        #expect(try h.jobs(.pending).allSatisfy { $0.attempts == 0 })

        try seedJob(h, "later", state: .deferred) {
            $0.stateReason = .uploadFailures
            $0.deferredSince = h.clock.now
            $0.nextAttemptAt = h.clock.now.addingTimeInterval(24 * 3600)
        }
        h.clock.advance(by: 25 * 3600)
        await h.run()
        #expect(try h.jobs(.deferred).isEmpty, "after 24 hours the cycle retries by itself")
    }

    @Test func skippedJobsRetryOnDemandAndKeepTheirRemoteId() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        try seedJob(h, "skip", state: .skipped) {
            $0.stateReason = .permanentError
            $0.remoteId = "known-remote-id"
            $0.attempts = 3
        }
        try await h.coordinator.retrySkipped(nil)
        let job = try #require(try h.jobs(.pending).first)
        #expect(job.remoteId == "known-remote-id" && job.attempts == 0 && job.stateReason == nil)
    }
}
