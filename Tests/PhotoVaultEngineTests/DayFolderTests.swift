import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// T9, T10 and the move worker (spec 8.7).
@Suite struct DayFolderTests {
    enum Target: String, CaseIterable, Sendable { case drive, nas }

    private func harness(_ target: Target) async throws -> (Harness, FakeDestination) {
        let h = try await Harness.organized()
        try await h.withoutSidecarsAndViews()
        switch target {
        case .drive: try h.addDrive(scope: .full)
        case .nas: try h.addNAS(scope: .full)
        }
        return (h, target == .drive ? h.drive : h.nas)
    }

    private func baseline(_ h: Harness, _ target: Target) async throws {
        switch target {
        case .drive: try await h.baseline(.googleDrive)
        case .nas: try await h.baseline(h.nasId)
        }
    }

    @Test(arguments: Target.allCases)
    func t9EleventhCameraPhotoSplitsTheDayAndScreenshotsDoNotCount(_ target: Target) async throws {
        let (h, destination) = try await harness(target)
        await h.addCameraAssets(10, recordChange: false)
        for index in 0..<8 { await h.add(h.snapshot("s\(index)", daysAgo: 3, subtypes: .photoScreenshot), camera: false, recordChange: false) }
        try await baseline(h, target)
        await h.settle()
        var paths = await h.backupPaths(destination)
        #expect(paths.count == 18)
        #expect(paths.filter { $0.hasPrefix("2026/10/") && $0.split(separator: "/").count == 3 }.count == 10, "camera files sit in the month folder: \(paths)")
        #expect(paths.filter { $0.hasPrefix("Screenshots/2026/10/") }.count == 8)
        #expect(try h.dayStat(organizationDay)?.promoted == false)

        await h.add(h.snapshot("c10", daysAgo: 3))
        await h.settle()
        paths = await h.backupPaths(destination)
        #expect(paths.count == 19)
        #expect(paths.filter { $0.hasPrefix("2026/10/\(organizationDay)/") }.count == 11, "all 11 camera files moved into the day folder: \(paths)")
        #expect(paths.filter { $0.hasPrefix("Screenshots/2026/10/") && $0.split(separator: "/").count == 4 }.count == 8, "screenshots stay put")
        #expect(try h.dayStat(organizationDay)?.promoted == true)
        #expect(try h.moveJobs(.pending, destination: destination.id).isEmpty)
        #expect(try h.jobs().allSatisfy { $0.state == .done })
        #expect(await destination.contractViolations.isEmpty)
    }

    @Test(arguments: Target.allCases)
    func t9aJobHeldInUploadingWhenTheDayIsPromotedEndsInTheDayFolder(_ target: Target) async throws {
        let (h, destination) = try await harness(target)
        await h.addCameraAssets(6, recordChange: false)
        try await baseline(h, target)
        let context = try h.read { db in
            try PipelineContext(db, snapshot: SettingsSnapshot(settings: GlobalSettings(), timeZone: utc), now: h.clock.now, utiResolver: FakeUTIResolver())
        }
        let fired = Flag()
        h.injector.onReach { point in
            guard point == .afterStartUpload, fired.takeFirst() else { return }
            try h.store.write { db in _ = try DayFolderPromoter.promote(db, day: organizationDay, context: context) }
        }
        await h.settle()
        let paths = await h.backupPaths(destination)
        #expect(fired.isSet)
        #expect(paths.count == 6)
        #expect(paths.allSatisfy { $0.hasPrefix("2026/10/\(organizationDay)/") }, "every file of a promoted day is in the day folder: \(paths)")
        #expect(try h.jobs().allSatisfy { $0.state == .done && $0.remoteLogicalParent == "camera/2026/10/\(organizationDay)" })
    }

    @Test func promotionQueuesMovesOnlyForDoneJobsAndNeverDemotes() async throws {
        let (h, drive) = try await harness(.drive)
        await h.addCameraAssets(4, recordChange: false)
        try await baseline(h, .drive)
        await h.settle()
        // A fifth asset whose job is still pending when the day is promoted.
        let pending = AssetKey.local("late")
        try h.write { db in
            let context = try PipelineContext(db, snapshot: SettingsSnapshot(settings: GlobalSettings(), timeZone: utc), now: h.clock.now, utiResolver: FakeUTIResolver())
            var late = UploadJob(destinationId: .googleDrive, assetKey: pending, resType: .photo, origin: .incremental, updatedAt: h.clock.now)
            try JobRepository.save(db, &late)
            _ = try DayFolderPromoter.promote(db, day: organizationDay, context: context)
        }
        let queued = try h.moveJobs(.pending, destination: .googleDrive)
        #expect(queued.count == 4, "one move per done file, none for the pending job")
        #expect(queued.allSatisfy { $0.operation == .moveFile && $0.fromValue == "camera/2026/10" && $0.toValue == "camera/2026/10/\(organizationDay)" })
        await h.settle()
        #expect(await h.backupPaths(drive).allSatisfy { $0.hasPrefix("2026/10/\(organizationDay)/") })

        // Deleting assets lowers the count below N but the day stays promoted.
        try h.write { db in
            try db.execute(sql: "UPDATE asset SET deleted_at = ?", arguments: [h.clock.now])
            try EngineQueries.recountDay(db, day: organizationDay, settings: GlobalSettings())
        }
        #expect(try h.dayStat(organizationDay)?.promoted == true)
    }

    @Test func t10ResortReportsTheNumberOfFilesItMoves() async throws {
        let (h, drive) = try await harness(.drive)
        try await h.update { $0.dayFolderThreshold = 20 }
        await h.addCameraAssets(15, recordChange: false)
        try await baseline(h, .drive)
        await h.settle()
        #expect(try h.dayStat(organizationDay)?.promoted == false)
        #expect(await h.backupPaths(drive).allSatisfy { $0.split(separator: "/").count == 3 })

        let untouched = try await h.coordinator.resortPreview()
        #expect(untouched == ResortPreview(days: 0, files: 0), "N is still 20")
        try await h.update { $0.dayFolderThreshold = 10 }
        let preview = try await h.coordinator.resortPreview()
        #expect(preview == ResortPreview(days: 1, files: 15))
        #expect(try h.moveJobs(.pending, destination: .googleDrive).isEmpty, "previewing changes nothing")

        let applied = try await h.coordinator.resortApply()
        #expect(applied == preview)
        let before = await drive.operationLog.filter { $0 == .move }.count
        await h.settle()
        #expect(await drive.operationLog.filter { $0 == .move }.count - before == preview.files)
        #expect(await h.backupPaths(drive).allSatisfy { $0.hasPrefix("2026/10/\(organizationDay)/") })

        // Raising N again never demotes.
        try await h.update { $0.dayFolderThreshold = 100 }
        #expect(try await h.coordinator.resortApply() == ResortPreview(days: 0, files: 0))
        #expect(try h.dayStat(organizationDay)?.promoted == true)
    }

    @Test func moveJobsFailAfterEightFailuresAndRetryUntilThen() async throws {
        let (h, drive) = try await harness(.drive)
        await h.addCameraAssets(3, recordChange: false)
        try await baseline(h, .drive)
        await h.settle()
        try await h.update { $0.dayFolderThreshold = 1 }
        _ = try await h.coordinator.resortApply()
        await drive.failNext(.move, with: .itemRejected(reason: "boom"), times: 100)
        for _ in 0..<12 { await h.run() }
        let failed = try h.moveJobs(.failed, destination: .googleDrive)
        #expect(failed.count == 3)
        #expect(failed.allSatisfy { $0.attempts == MoveJob.maxAttempts + 1 && $0.lastError != nil })
        #expect(try h.moveJobs(.pending, destination: .googleDrive).isEmpty)
    }

    @Test func pendingJobsOfDeletedAssetsThatNeverUploadedAreCancelled() async throws {
        let (h, _) = try await harness(.drive)
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("gone", daysAgo: 3), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.fakePhotos.setAuthorization(.authorized)
        // Hold the upload so the job stays pending, then delete the asset in Photos.
        await h.drive.setStatus(.unavailable(.offline))
        await h.run()
        #expect(try h.jobs(.pending).count == 1)
        await h.fakePhotos.delete(localId: "gone")
        await h.run()
        #expect(try h.jobs(.pending).isEmpty)
        #expect(try h.jobs(.cancelled).count == 1)
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func takeFirst() -> Bool { lock.withLock { defer { value = true }; return !value } }
    var isSet: Bool { lock.withLock { value } }
}
