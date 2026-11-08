import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// The integrity check judges a consistent picture: database first, listing second, and a file
/// missing from the listing is asked for by id before it counts as gone (FR-47).
@Suite struct IntegrityRobustnessTests {
    private func driveLife() async throws -> (Harness, ControllableDrive) {
        let h = try await Harness()
        let wrapper = ControllableDrive(h.drive)
        h.overrides = [wrapper]
        await h.env.destinations.add(wrapper)
        try h.addDrive(scope: .full)
        for index in 0..<3 { await h.add(h.snapshot("p\(index)", daysAgo: Double(index + 1)), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.settle()
        return (h, wrapper)
    }

    @Test func aFileTheListingOmitsButThatExistsIsNotReportedMissing() async throws {
        let (h, drive) = try await driveLife()
        drive.hidesListing = true
        let report = try await h.coordinator.runIntegrityCheck(.googleDrive)
        #expect(report.checked == 3 && report.missing == 0)
        #expect(try h.jobs(.done).count == 3)
        #expect(try h.jobs(.missingRemote).isEmpty)
    }

    @Test func aFileThatReallyIsGoneIsStillReportedWhileTheListingOmitsEverything() async throws {
        let (h, drive) = try await driveLife()
        drive.hidesListing = true
        await h.drive.externallyDelete(try #require(await h.drive.files.first).id)
        let report = try await h.coordinator.runIntegrityCheck(.googleDrive)
        #expect(report.missing == 1)
        #expect(try h.jobs(.missingRemote).count == 1)
    }

    @Test func aProbeThatFailsEndsTheCheckWithoutMarkingAnything() async throws {
        let (h, drive) = try await driveLife()
        drive.hidesListing = true
        await h.drive.failNext(.probe, with: .offline)
        await #expect(throws: DestinationError.self) { try await h.coordinator.runIntegrityCheck(.googleDrive) }
        #expect(try h.jobs(.missingRemote).isEmpty)
    }

    @Test func aJobThatChangedSinceTheSnapshotIsNotMarkedMissing() async throws {
        let h = try await Harness()
        try h.addNAS(scope: .full)
        for index in 0..<2 { await h.add(h.snapshot("p\(index)", daysAgo: Double(index + 1)), recordChange: false) }
        try await h.baseline(h.nasId)
        await h.settle()
        let checker = await h.coordinator.hardening.integrity
        let snapshot = try await checker.doneJobs(h.nasId)
        #expect(snapshot.count == 2)
        // The file was moved by the move worker after the snapshot: its job now points elsewhere.
        try h.write { db in
            try db.execute(sql: "UPDATE upload_job SET remote_id = 'moved/' || remote_id WHERE id = (SELECT MIN(id) FROM upload_job)")
        }
        let marked = try await checker.markMissing(snapshot)
        #expect(marked.count == 1, "only the job that is unchanged is judged")
        #expect(try h.jobs(.done).count == 1 && (try h.jobs(.missingRemote).count) == 1)
    }
}
