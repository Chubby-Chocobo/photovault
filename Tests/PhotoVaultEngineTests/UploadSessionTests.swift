import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// A resumable session belongs to one content: it is reused only for the content it was opened for.
@Suite struct UploadSessionTests {
    /// One Drive photo, crashed right after its session was persisted.
    private func interrupted() async throws -> (Harness, UploadJob) {
        let h = try await Harness { $0.maxConcurrentUploadsPerDestination = 1 }
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("video", daysAgo: 1), recordChange: false)
        try await h.baseline(.googleDrive)
        h.injector.arm(.afterSessionPersisted)
        await h.run()
        let stuck = try #require(try h.jobs(.uploading).first)
        #expect(stuck.sessionRef != nil && stuck.sessionMd5 != nil && stuck.remoteId != nil)
        try await h.restart()
        return (h, stuck)
    }

    @Test func aSessionOpenedForOtherContentIsDroppedAndTheSameIdIsUsedForANewUpload() async throws {
        let (h, stuck) = try await interrupted()
        // The video was trimmed after the session was opened: the session's checksum is another one.
        try h.write { db in try db.execute(sql: "UPDATE upload_job SET session_md5 = 'md5-of-the-old-content'") }
        try await h.coordinator.start()
        await h.run()

        let log = await h.drive.operationLog
        #expect(!log.contains(.resume), "the old session is not offered the new bytes")
        let files = await h.drive.files
        #expect(files.map(\.id) == [try #require(stuck.remoteId)], "one file, under the id reserved for it")
        let job = try #require(try h.jobs().first)
        #expect(job.state == .done && job.sessionRef == nil && job.sessionMd5 == nil)
    }

    @Test func aSessionForTheSameContentIsStillResumed() async throws {
        let (h, _) = try await interrupted()
        try await h.coordinator.start()
        await h.run()
        #expect(await h.drive.operationLog.contains(.resume))
        #expect(try h.jobs(.done).count == 1)
    }

    @Test func aSessionTheDestinationRefusesToResumeIsClearedEvenWhenTheNewUploadFails() async throws {
        let (h, stuck) = try await interrupted()
        await h.drive.failNext(.resume, with: .sessionExpired)
        await h.drive.failNext(.upload, with: .itemRejected(reason: "boom"))
        try await h.coordinator.start()
        await h.run()
        let job = try #require(try h.jobs().first)
        #expect(job.state == .pending && job.attempts == 1)
        #expect(job.sessionRef == nil && job.sessionMd5 == nil, "the refused session is not kept for the next attempt")
        #expect(job.remoteId == stuck.remoteId, "the reserved id survives")
        h.clock.advance(by: 3600)
        await h.run()
        let files = await h.drive.files
        #expect(files.map(\.id) == [try #require(stuck.remoteId)])
        #expect(try h.jobs(.done).count == 1)
    }

    @Test func aResumeThatFailsOnTheItemDropsTheSession() async throws {
        let (h, _) = try await interrupted()
        await h.drive.failNext(.resume, with: .itemRejected(reason: "size mismatch"))
        try await h.coordinator.start()
        await h.run()
        let job = try #require(try h.jobs().first { $0.state != .done })
        #expect(job.sessionRef == nil && job.sessionMd5 == nil)
        h.clock.advance(by: 3600)
        await h.run()
        #expect(try h.jobs(.done).count == 1)
    }

    @Test func retryingASkippedJobStartsWithoutTheOldSession() async throws {
        let (h, _) = try await interrupted()
        try h.write { db in
            try db.execute(sql: "UPDATE upload_job SET state = 'skipped', state_reason = 'checksumMismatch'")
        }
        try await h.coordinator.retrySkipped(nil)
        let job = try #require(try h.jobs().first)
        #expect(job.state == .pending && job.sessionRef == nil && job.sessionMd5 == nil && job.remoteId != nil)
    }
}
