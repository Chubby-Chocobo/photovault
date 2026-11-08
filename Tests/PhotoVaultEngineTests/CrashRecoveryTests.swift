import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// T16/T17/T43: kill the engine at every step of delivering a file, rebuild it over the same
/// database, staging directory and destination, and check that nothing is lost or duplicated.
@Suite struct CrashRecoveryTests {
    enum Target: String, CaseIterable, Sendable { case drive, nas }

    private func prepare(_ target: Target) async throws -> (Harness, FakeDestination) {
        let h = try await Harness { $0.maxConcurrentUploadsPerDestination = 1 }
        switch target {
        case .drive: try h.addDrive(scope: .full)
        case .nas: try h.addNAS(scope: .full)
        }
        for i in 0..<3 { await h.add(h.snapshot("p\(i)", daysAgo: Double(i + 1)), recordChange: false) }
        switch target {
        case .drive: try await h.baseline(.googleDrive)
        case .nas: try await h.baseline(h.nasId)
        }
        return (h, target == .drive ? h.drive : h.nas)
    }

    private func settle(_ h: Harness, rounds: Int = 4) async throws {
        try await h.restart()
        try await h.coordinator.start()
        for _ in 0..<rounds {
            await h.run()
            h.clock.advance(by: 3 * 3600)
        }
    }

    private func assertConsistent(_ h: Harness, _ destination: FakeDestination, expectedFiles: Int = 3) async throws {
        let files = await destination.files
        #expect(files.count == expectedFiles, "files at the destination: \(files.map(\.name))")
        #expect(Set(files.map(\.name)).count == files.count, "no duplicate names")
        let hashes = files.compactMap { $0.content?.sha256 }
        #expect(Set(hashes).count == files.count, "no duplicate content")
        #expect(await destination.contractViolations.isEmpty)
        let states = try h.jobs().map(\.state)
        #expect(states.allSatisfy { $0 == .done }, "jobs: \(states)")
        #expect(h.stagingFiles().isEmpty, "staging is empty: \(h.stagingFiles())")
        let folders = try h.read { db in try RemoteFolderRepository.fetchAll(db, destinationId: destination.id) }
        #expect(folders.allSatisfy { $0.created }, "every folder row is confirmed")
        let twins = Dictionary(grouping: await destination.folders.filter { $0.id != "root" }, by: { "\($0.parentId)/\($0.name)" })
        #expect(twins.values.allSatisfy { $0.count == 1 }, "no folder was created twice")
    }

    @Test(arguments: Target.allCases, CrashPoint.allCases.filter { $0 != .afterExportBeforeCommit })
    func crashAtEveryUploadStep(_ target: Target, _ point: CrashPoint) async throws {
        let (h, destination) = try await prepare(target)
        h.injector.arm(point)
        await h.run()
        let reservationOnly: Set<CrashPoint> = [.afterFolderIdPersisted, .afterFileIdReserved, .afterFileIdPersisted, .afterSessionPersisted]
        if target == .drive || !reservationOnly.contains(point) {
            #expect(h.injector.visited.contains(point), "the crash point was reached")
        }
        try await settle(h)
        try await assertConsistent(h, destination)
    }

    @Test(arguments: Target.allCases)
    func crashDuringExportLeavesNoStagingGarbageAndExportsAgain(_ target: Target) async throws {
        let (h, destination) = try await prepare(target)
        h.injector.arm(.afterExportBeforeCommit)
        await h.run()
        let exporting = try h.read { db in try ResourceRepository.fetch(db, stagingState: .exporting) }
        #expect(!exporting.isEmpty, "the crash left a resource in exporting")
        try await settle(h)
        try await assertConsistent(h, destination)
    }

    @Test(arguments: Target.allCases)
    func destinationCrashesAfterTheCreateEffect(_ target: Target) async throws {
        for op in [FakeDestination.Operation.upload, .ensureFolder] {
            let (h, destination) = try await prepare(target)
            await destination.crashAfterEffect(op)
            await h.run()
            try await settle(h)
            try await assertConsistent(h, destination)
        }
    }

    @Test func uploadFinishedButNotCommittedIsCompletedByRecoveryWithoutUploadingAgain() async throws {
        let (h, drive) = try await prepare(.drive)
        h.injector.arm(.afterUploadBeforeCommit)
        await h.run()
        let uploading = try h.jobs(.uploading)
        #expect(uploading.count == 1)
        #expect(uploading[0].sessionMd5 != nil && uploading[0].remoteId != nil)
        let uploadsBefore = await drive.operationLog.filter { $0 == .upload }.count

        try await h.restart()
        let summary = try await h.coordinator.start()
        #expect(summary.jobsCompleted == 1)
        #expect(try h.jobs(.uploading).isEmpty)
        #expect(await drive.operationLog.filter { $0 == .upload }.count == uploadsBefore, "recovery probed instead of uploading")
        #expect(try h.jobs(.done).count == 1)
    }

    @Test func t43MacOffForAWeekWithAnOpenSessionReusesTheReservedId() async throws {
        let (h, drive) = try await prepare(.drive)
        h.injector.arm(.afterSessionPersisted)
        await h.run()
        let stuck = try #require(try h.jobs(.uploading).first)
        let reserved = try #require(stuck.remoteId)
        h.clock.advance(by: 8 * 86_400)
        await drive.expireSessions()
        try await settle(h)
        try await assertConsistent(h, drive)
        let ids = await drive.files.map(\.id)
        #expect(ids.contains(reserved), "the interrupted file kept its reserved id")
    }

    @Test func interruptedSessionIsResumedWhenItIsStillOpen() async throws {
        let (h, drive) = try await prepare(.drive)
        h.injector.arm(.afterSessionPersisted)
        await h.run()
        try await settle(h)
        try await assertConsistent(h, drive)
        #expect(await drive.operationLog.contains(.resume))
    }

    @Test func crashBeforeRecoveryOfAFolderKeepsTheReservedFolderId() async throws {
        let (h, drive) = try await prepare(.drive)
        h.injector.arm(.afterFolderIdPersisted)
        await h.run()
        let pending = try h.read { db in try RemoteFolderRepository.fetchAll(db, destinationId: .googleDrive) }
        #expect(pending.count == 1 && !pending[0].created && pending[0].remoteId != nil)
        let reserved = pending[0].remoteId
        try await settle(h)
        try await assertConsistent(h, drive)
        let folderIds = await drive.folders.map(\.id)
        #expect(folderIds.contains(reserved ?? ""))
    }

    @Test func recoveryConfirmsAFolderCreatedJustBeforeTheCrash() async throws {
        let (h, drive) = try await prepare(.drive)
        h.injector.arm(.afterFolderCreated)
        await h.run()
        try await h.restart()
        let summary = try await h.coordinator.start()
        #expect(summary.foldersConfirmed == 1)
        let rows = try h.read { db in try RemoteFolderRepository.fetchAll(db, destinationId: .googleDrive) }
        #expect(rows.allSatisfy { $0.created })
        try await settle(h)
        try await assertConsistent(h, drive)
    }

    @Test func recoveryWithAnUnreachableDestinationLeavesTheJobForLater() async throws {
        let (h, drive) = try await prepare(.drive)
        h.injector.arm(.afterUploadBeforeCommit)
        await h.run()
        await drive.failNext(.probe, with: .offline)
        try await h.restart()
        let summary = try await h.coordinator.start()
        #expect(summary.jobsLeftForLater == 1)
        #expect(try h.jobs(.uploading).count == 1)
        try await settle(h)
        try await assertConsistent(h, drive)
    }

    @Test func recoveryResetsExportingAndRemovesOrphans() async throws {
        let (h, _) = try await prepare(.drive)
        _ = try await h.coordinator.scanner.run()
        let url = try h.seedStaged("ghost")
        try h.write { db in
            try db.execute(sql: "UPDATE resource SET staging_state = 'exporting' WHERE asset_key = 'l:ghost'")
        }
        try await h.restart()
        let summary = try await h.coordinator.start()
        #expect(summary.exportsReset == 1)
        #expect(summary.orphanFilesRemoved == 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func dayPromotedWhileUploadingCreatesAMoveJobInTheCompletionTransaction() async throws {
        let h = try await Harness { $0.maxConcurrentUploadsPerDestination = 1 }
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("d", daysAgo: 1), recordChange: false)
        try await h.baseline(.googleDrive)
        let created = try #require(await h.fakePhotos.snapshotCreation("d"))
        let day = ArchiveDay(date: created, timeZone: utc)
        let store = h.store
        let now = h.clock.now
        h.injector.onReach { point in
            if point == .afterUploadBeforeCommit {
                try store.write { db in _ = try DayStatRepository.promote(db, day: day, now: now) }
            }
        }
        await h.run()
        let moves = try h.read { db in try MoveJobRepository.fetch(db, destinationId: .googleDrive, state: .pending) }
        #expect(moves.count == 1)
        #expect(moves[0].operation == .moveFile)
        #expect(moves[0].fromValue == "camera/\(day.yearString)/\(day.monthString)")
        #expect(moves[0].toValue == "camera/\(day.yearString)/\(day.monthString)/\(day)")
        #expect(try h.jobs(.done).count == 1)
    }

    @Test func uploadsTargetThePromotedFolderWhenThePromotionHappenedBeforehand() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("e", daysAgo: 1), recordChange: false)
        try await h.baseline(.googleDrive)
        let created = try #require(await h.fakePhotos.snapshotCreation("e"))
        let day = ArchiveDay(date: created, timeZone: utc)
        _ = try await h.coordinator.scanner.run()
        try await h.coordinator.finalize.runAfterScan()
        try h.write { db in _ = try DayStatRepository.promote(db, day: day, now: h.clock.now) }
        await h.run()
        let file = try #require(await h.drive.files.first)
        #expect(await h.drive.path(of: file.id).contains("/\(day)/"))
        #expect(try h.read { db in try MoveJobRepository.fetch(db, destinationId: .googleDrive, state: .pending) }.isEmpty)
    }
}
