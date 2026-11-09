import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// A resumed session finishes in the folder it was opened for, which may no longer be the planned one.
@Suite struct UploadResumeParentTests {
    @Test func aResumedUploadRecordsTheFolderItLandedInAndTheFileIsMovedToTheDayFolder() async throws {
        let h = try await Harness.organized { $0.maxConcurrentUploadsPerDestination = 1 }
        try await h.withoutSidecarsAndViews()
        try h.addDrive(scope: .full)
        await h.addCameraAssets(1, recordChange: false)
        try await h.baseline(.googleDrive)
        h.injector.arm(.afterSessionPersisted)
        await h.run()
        #expect(try h.jobs(.uploading).first?.sessionRef != nil)
        try await h.restart()

        // The day crosses the threshold while the session is still open.
        try h.write { db in
            let context = try PipelineContext(
                db, snapshot: SettingsSnapshot(settings: GlobalSettings(), timeZone: utc), now: h.clock.now, utiResolver: FakeUTIResolver())
            _ = try DayFolderPromoter.promote(db, day: organizationDay, context: context)
        }
        try await h.coordinator.start()
        await h.run()

        #expect(await h.drive.operationLog.contains(.resume))
        let job = try #require(try h.jobs().first)
        #expect(job.state == .done)
        // The file landed in the month folder the session was opened for; the move to the day folder
        // was queued from there (and may already have run in the same round).
        let moves = try h.moveJobs(.pending, destination: .googleDrive) + h.moveJobs(.done, destination: .googleDrive)
        #expect(moves.count == 1 && moves[0].fromValue == "camera/2026/10" && moves[0].toValue == "camera/2026/10/\(organizationDay)")

        await h.settle()
        #expect(await h.backupPaths(h.drive).allSatisfy { $0.hasPrefix("2026/10/\(organizationDay)/") })
        #expect(try h.jobs().first?.remoteLogicalParent == "camera/2026/10/\(organizationDay)")
        #expect(await h.drive.contractViolations.isEmpty)
    }
}
