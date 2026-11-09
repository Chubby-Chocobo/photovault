import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// What starts a recovery (FR-51 triggers, FR-52, FR-08) and the zero-match guard.
@Suite struct RecoveryTriggerTests {
    private func firstLife(assets: Int = 3) async throws -> Harness {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        for index in 0..<assets { await h.add(h.snapshot("p\(index)", daysAgo: Double(index + 1)), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.settle()
        return h
    }

    private func decisions(_ h: Harness) async -> [OwnerDecision] { await h.coordinator.pendingOwnerDecisions() }

    @Test func aNewEmptyDestinationIsNotRecovered() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("a", daysAgo: 2), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        #expect(await h.drive.files.count == 1)
        #expect(try h.activity().allSatisfy { $0.kind != .recovered })
    }

    /// Drive lists the whole account: the new root itself, an empty folder of it and another
    /// PhotoVault root's files are not backup data of this destination.
    @Test func aNewRootIsNotMistakenForBackupDataInAnAccountWithOtherRoots() async throws {
        let h = try await Harness()
        await h.drive.setListsWholeAccount(true)
        let schema = [AppPropertyKey.schema: AppPropertyCodec.schemaVersion]
        await h.drive.put(.init(id: "root", name: "Camera Uploads", parentId: "", kind: .folder, appProperties: schema.merging([AppPropertyKey.root: "1"]) { a, _ in a }))
        await h.drive.put(.init(id: "empty", name: "2027", parentId: "root", kind: .folder, appProperties: schema))
        await h.drive.put(.init(id: "other", name: "Old Mac", parentId: "", kind: .folder, appProperties: schema))
        await h.drive.put(.init(id: "old-file", name: "x.HEIC", parentId: "other", kind: .file, appProperties: schema))
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("a", daysAgo: 2), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.settle()
        #expect(try h.activity().allSatisfy { !$0.message.contains("đã có dữ liệu sao lưu") })
        #expect(try h.activity().allSatisfy { $0.kind != .recovered })
        #expect(try h.jobs(.done).count >= 1)
    }

    @Test func aFileUnderTheRootInAWholeAccountListingStillRequiresRecovery() async throws {
        let h = try await Harness()
        await h.drive.setListsWholeAccount(true)
        let schema = [AppPropertyKey.schema: AppPropertyCodec.schemaVersion]
        await h.drive.put(.init(id: "m", name: "01", parentId: "root", kind: .folder, appProperties: schema))
        await h.drive.put(.init(id: "f", name: "x.HEIC", parentId: "m", kind: .file, appProperties: schema))
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("a", daysAgo: 2), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.run()
        #expect(try h.destinationRecord(.googleDrive).recoveryRequired)
    }

    @Test func aReusedRootIsRecoveredBeforeAnythingIsUploaded() async throws {
        let h = try await firstLife()
        let files = await h.drive.files.map(\.id).sorted()
        try await h.loseDatabase()
        try h.addDrive(scope: .full)
        try await h.coordinator.adoptExistingRoot(.googleDrive, rootId: "root")
        let record = try h.destinationRecord(.googleDrive)
        #expect(record.recoveryRequired && record.status == .paused(.recovering))
        try await h.baseline(.googleDrive)
        await h.settle()
        #expect(await h.drive.files.map(\.id).sorted() == files)
        #expect(try h.jobs(.done).count == 3)
        #expect(try h.destinationRecord(.googleDrive).status == .active)
    }

    @Test func adoptingARootThatIsMissingOrTrashedIsRefused() async throws {
        let h = try await firstLife(assets: 1)
        await h.drive.externallyTrash("root")
        await #expect(throws: RootProblemError.stillTrashed) { try await h.coordinator.adoptExistingRoot(.googleDrive, rootId: "root") }
        await #expect(throws: RootProblemError.stillMissing) { try await h.coordinator.adoptExistingRoot(.googleDrive, rootId: "nope") }
        #expect(try h.destinationRecord(.googleDrive).recoveryRequired == false, "a refused adoption changes nothing")
    }

    @Test func aRestoredBackupFindsTheFilesUploadedAfterTheBackupInsteadOfUploadingThemAgain() async throws {
        let folder = try TestFiles.temporaryDirectory("db")
        let dbURL = folder.appendingPathComponent("photovault.sqlite")
        let h = try await Harness(store: try Store.open(at: dbURL))
        try h.addDrive(scope: .full)
        for index in 0..<3 { await h.add(h.snapshot("old\(index)", daysAgo: Double(index + 1)), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.settle()
        let backups = DatabaseBackup(directory: folder.appendingPathComponent("backups"))
        try backups.backup(h.store, now: h.clock.now)

        // Two more photos are backed up after the last backup was taken.
        for index in 0..<2 { await h.add(h.snapshot("late\(index)", daysAgo: 0.5), recordChange: true) }
        await h.settle()
        let files = await h.drive.files.map(\.id).sorted()
        #expect(files.count == 5)
        let uploads = await h.count(of: .upload, on: h.drive)

        // The database is damaged: the newest backup comes back and every destination needs recovery.
        let restored = try #require(try backups.restoreNewest(to: dbURL, now: h.clock.now))
        try await h.replaceStore(restored)
        #expect(try h.destinationRecord(.googleDrive).recoveryRequired, "restoring marks every destination")
        await h.run()
        #expect(await h.count(of: .upload, on: h.drive) == uploads, "nothing was uploaded before or after the recovery")
        await h.settle()
        #expect(await h.drive.files.map(\.id).sorted() == files)
        #expect(try h.jobs(.done).count == 5)
        #expect(try h.destinationRecord(.googleDrive).status == .active)
    }

    @Test func changingTheRootToANewEmptyOneUploadsEverythingThere() async throws {
        let h = try await firstLife(assets: 2)
        let oldFiles = await h.drive.files.map(\.id).sorted()
        let reserved = try #require(try await h.drive.reserveIds(count: 1, kind: .files).first)
        _ = try await h.drive.createRoot(reservedId: reserved, name: "New root", appProperties: AppPropertyCodec.rootProperties(archiveTimezone: utc))
        try await h.coordinator.changeDriveRoot(.googleDrive, rootId: reserved, rootName: "New root", rootHasContent: false)
        let record = try h.destinationRecord(.googleDrive)
        #expect(record.config.driveRootId == reserved && !record.recoveryRequired && record.status == .active)
        #expect(try h.jobs().isEmpty, "the old location's jobs are gone")
        await h.settle()
        let newFiles = await h.drive.files.filter { !oldFiles.contains($0.id) }
        #expect(newFiles.count == 2, "both photos were uploaded again into the new root")
        for file in newFiles {
            let path = await h.drive.path(of: file.id)
            #expect(!path.isEmpty)
            var top = file
            while top.parentId != reserved, let parent = await h.drive.items[top.parentId] { top = parent }
            #expect(top.parentId == reserved)
        }
        #expect(await h.drive.files.filter { oldFiles.contains($0.id) }.count == 2, "the old root is untouched")
    }

    @Test func changingTheRootToOneWithContentRecoversIt() async throws {
        let h = try await firstLife(assets: 2)
        let files = await h.drive.files.map(\.id).sorted()
        try await h.coordinator.changeDriveRoot(.googleDrive, rootId: "root", rootName: "Camera Uploads", account: DriveAccount(id: "u2", email: "b@example.com"), rootHasContent: true)
        let record = try h.destinationRecord(.googleDrive)
        #expect(record.accountEmail == "b@example.com" && record.recoveryRequired)
        await h.settle()
        #expect(await h.drive.files.map(\.id).sorted() == files)
        #expect(try h.jobs(.done).count == 2)
    }

    // MARK: Zero-match guard

    @Test func whenListingFindsNothingMatchableWhileTheRootHasFilesNothingIsEnqueued() async throws {
        let h = try await firstLife()
        let files = await h.drive.files.map(\.id).sorted()
        let wrapper = ControllableDrive(h.drive)
        h.overrides = [wrapper]
        wrapper.hidesListing = true
        try await h.loseDatabase()
        try h.addDrive(scope: .full)
        try await h.coordinator.adoptExistingRoot(.googleDrive, rootId: "root")
        try await h.baseline(.googleDrive)
        await h.settle()

        let record = try h.destinationRecord(.googleDrive)
        #expect(record.status == .paused(.recovering) && record.recoveryRequired, "stays paused and asks the owner")
        #expect(try h.jobs().isEmpty, "nothing was enqueued")
        #expect(await h.drive.files.map(\.id).sorted() == files, "nothing was uploaded")
        #expect(await decisions(h).contains(.recoveryNeedsDecision(.googleDrive)))
        #expect(try h.activity().contains { $0.message.contains("cần owner quyết định") })

        // The owner presses recovery once the listing works: the files are found.
        wrapper.hidesListing = false
        let outcome = try await h.coordinator.startRecovery(.googleDrive)
        guard case .recovered(let stats) = outcome else {
            Issue.record("expected a recovery, got \(outcome)")
            return
        }
        #expect(stats.matched == 3)
        await h.settle()
        #expect(await h.drive.files.map(\.id).sorted() == files)
        #expect(await decisions(h).isEmpty)
    }

    @Test func filesThatMatchNoAssetStopTheRecoveryUntilTheOwnerDecides() async throws {
        let h = try await firstLife()
        let files = await h.drive.files.map(\.id).sorted()
        // The library of this Mac holds other photos now.
        for index in 0..<3 { await h.fakePhotos.delete(localId: "p\(index)") }
        for index in 0..<3 { await h.add(h.snapshot("other\(index)", daysAgo: Double(index + 10)), recordChange: false) }
        try await h.loseDatabase()
        try h.addDrive(scope: .full)
        try await h.coordinator.adoptExistingRoot(.googleDrive, rootId: "root")
        try await h.baseline(.googleDrive)
        await h.settle()
        #expect(await h.drive.files.map(\.id).sorted() == files, "nothing new was uploaded")
        #expect(await decisions(h).contains(.recoveryNeedsDecision(.googleDrive)))
        let listCalls = await h.count(of: .list, on: h.drive)
        await h.settle()
        #expect(await h.count(of: .list, on: h.drive) == listCalls, "the owner is not asked again every cycle")

        try await h.coordinator.proceedWithoutRecovery(.googleDrive)
        await h.settle()
        #expect(try h.destinationRecord(.googleDrive).status == .active)
        #expect(await h.drive.files.count == 6, "the owner accepted: the new photos were uploaded, the old backup untouched")
        #expect(await h.drive.files.filter { files.contains($0.id) }.count == 3)
        #expect(await decisions(h).isEmpty)
    }
}
