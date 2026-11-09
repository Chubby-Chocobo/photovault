import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// Day folders and the move worker (spec 8.7).
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
    func theFirstCameraPhotoOfADayIsUploadedStraightIntoItsDayFolder(_ target: Target) async throws {
        let (h, destination) = try await harness(target)
        await h.addCameraAssets(1, recordChange: false)
        for index in 0..<2 { await h.add(h.snapshot("s\(index)", daysAgo: 3, subtypes: .photoScreenshot), camera: false, recordChange: false) }
        try await baseline(h, target)
        await h.settle()
        var paths = await h.backupPaths(destination)
        #expect(paths.count == 3)
        #expect(paths.filter { $0.hasPrefix("Camera Uploads/\(organizationDay)/") }.count == 1, "\(paths)")
        #expect(paths.filter { $0.hasPrefix("Screenshots/\(organizationDay)/") }.count == 2, "\(paths)")
        #expect(try h.dayStat(organizationDay)?.promoted == true, "promoted at its first camera asset; screenshots do not count")

        await h.addCameraAssets(10, prefix: "more", recordChange: true)
        await h.settle()
        paths = await h.backupPaths(destination)
        #expect(paths.filter { $0.hasPrefix("Camera Uploads/\(organizationDay)/") }.count == 11, "\(paths)")
        #expect(await destination.operationLog.filter { $0 == .move }.isEmpty, "no file ever moves between folders")
        #expect(try h.moveJobs(.pending, destination: destination.id).isEmpty)
        #expect(try h.jobs().allSatisfy { $0.state == .done && $0.remoteLogicalParent != nil })
        #expect(await destination.contractViolations.isEmpty)
    }

    @Test(arguments: Target.allCases)
    func promotingTheDayWhileAFileIsUploadingDoesNotChangeWhereItLands(_ target: Target) async throws {
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
        #expect(paths.allSatisfy { $0.hasPrefix("Camera Uploads/\(organizationDay)/") }, "\(paths)")
        #expect(try h.jobs().allSatisfy { $0.state == .done && $0.remoteLogicalParent == "camera/\(organizationDay)" })
        #expect(await destination.operationLog.filter { $0 == .move }.isEmpty)
    }

    @Test func promotionNeverQueuesMovesAndNeverDemotes() async throws {
        let (h, drive) = try await harness(.drive)
        await h.addCameraAssets(4, recordChange: false)
        try await baseline(h, .drive)
        await h.settle()
        let context = try h.read { db in
            try PipelineContext(db, snapshot: SettingsSnapshot(settings: GlobalSettings(), timeZone: utc), now: h.clock.now, utiResolver: FakeUTIResolver())
        }
        // Already promoted by the first asset: promoting again does nothing and queues nothing.
        let again = try h.write { db in try DayFolderPromoter.promote(db, day: organizationDay, context: context) }
        #expect(!again)
        #expect(try h.moveJobs(.pending, destination: .googleDrive).isEmpty)
        #expect(await h.backupPaths(drive).allSatisfy { $0.hasPrefix("Camera Uploads/\(organizationDay)/") })

        // Deleting assets empties the day but it stays promoted.
        try h.write { db in
            try db.execute(sql: "UPDATE asset SET deleted_at = ?", arguments: [h.clock.now])
            try EngineQueries.recountDay(db, day: organizationDay, settings: GlobalSettings())
        }
        #expect(try h.dayStat(organizationDay)?.promoted == true)
    }

    @Test func renameJobsFailAfterEightFailuresAndRetryUntilThen() async throws {
        let (h, drive) = try await harness(.drive)
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        await h.addCameraAssets(3, recordChange: false, location: daLat)
        try await h.update { $0.placeNamesEnabled = false }
        try await baseline(h, .drive)
        await h.settle()
        try await h.update { $0.placeNamesEnabled = true }
        await drive.failNext(.rename, with: .itemRejected(reason: "boom"), times: 100)
        for _ in 0..<12 { await h.run() }
        let failed = try h.moveJobs(.failed, destination: .googleDrive)
        #expect(failed.count == 1)
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
