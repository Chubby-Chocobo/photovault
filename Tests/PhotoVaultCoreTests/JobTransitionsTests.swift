import Foundation
import Testing
@testable import PhotoVaultCore

@Suite struct JobTransitionsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func job(_ state: JobState = .pending, target: Int = 1, done: Int = 0) -> UploadJob {
        UploadJob(destinationId: .googleDrive, assetKey: .local("A"), resType: .photo, origin: .incremental,
                  state: state, targetGen: target, doneGen: done, updatedAt: now)
    }

    @Test func reserveSetsIdOnlyOnce() throws {
        let j = try JobTransitions.apply(.reserved(remoteId: "f1"), to: job(), now: now)
        #expect(j.remoteId == "f1")
        let again = try JobTransitions.apply(.reserved(remoteId: "f2"), to: j, now: now)
        #expect(again.remoteId == "f1")
    }

    @Test func pendingToUploadingCapturesGeneration() throws {
        let j = try JobTransitions.apply(.startUpload(generation: 3), to: job(target: 3), now: now)
        #expect(j.state == .uploading)
        #expect(j.uploadingGen == 3)
    }

    @Test func uploadingToDoneSetsDoneGenAndClearsSession() throws {
        var j = try JobTransitions.apply(.startUpload(generation: 1), to: job(), now: now)
        j = try JobTransitions.apply(.sessionStarted(SessionCheckpoint(sessionRef: "s", md5: "m", totalBytes: 1)), to: j, now: now)
        #expect(j.sessionRef == "s")
        j = try JobTransitions.apply(.uploadSucceeded(remoteId: "f1", finalName: "a.HEIC", parent: "camera/2026/11", verifiedHash: "m"), to: j, now: now)
        #expect(j.state == .done)
        #expect(j.doneGen == 1)
        #expect(j.sessionRef == nil && j.sessionMd5 == nil)
        #expect(j.uploadedHash == "m")
    }

    @Test func editDuringUploadIsNeverLost() throws {
        var j = try JobTransitions.apply(.startUpload(generation: 1), to: job(), now: now)
        j = try JobTransitions.apply(.contentChanged(targetGen: 2), to: j, now: now)
        #expect(j.state == .uploading)
        j = try JobTransitions.apply(.uploadSucceeded(remoteId: "f1", finalName: "a", parent: "p", verifiedHash: "m"), to: j, now: now)
        #expect(j.doneGen == 1)
        #expect(j.state == .pending)
        #expect(j.origin == .refresh)
        #expect(j.remoteId == "f1")
    }

    @Test func checksumMismatchSkipsAfterThreeAndKeepsRemoteId() throws {
        var j = try JobTransitions.apply(.reserved(remoteId: "f1"), to: job(), now: now)
        j = try JobTransitions.apply(.startUpload(generation: 1), to: j, now: now)
        for _ in 0..<3 {
            j = try JobTransitions.apply(.checksumMismatch, to: j, now: now)
            #expect(j.state == .uploading)
        }
        j = try JobTransitions.apply(.checksumMismatch, to: j, now: now)
        #expect(j.state == .skipped)
        #expect(j.stateReason == .checksumMismatch)
        #expect(j.remoteId == "f1")
    }

    @Test func stagingLostReturnsToPendingKeepingIdAndSession() throws {
        var j = try JobTransitions.apply(.reserved(remoteId: "f1"), to: job(), now: now)
        j = try JobTransitions.apply(.startUpload(generation: 1), to: j, now: now)
        j = try JobTransitions.apply(.sessionStarted(SessionCheckpoint(sessionRef: "s", md5: "m", totalBytes: 1)), to: j, now: now)
        j = try JobTransitions.apply(.stagingLost, to: j, now: now)
        #expect(j.state == .pending)
        #expect(j.remoteId == "f1" && j.sessionRef == "s")
    }

    @Test func itemFailuresDeferAfterEightAndDeferredSinceIsWrittenOnce() throws {
        var j = job()
        for i in 1...8 {
            j = try JobTransitions.apply(.itemFailure(message: "e", retryAt: now), to: j, now: now)
            #expect(j.state == .pending)
            #expect(j.attempts == i)
        }
        j = try JobTransitions.apply(.itemFailure(message: "e", retryAt: now), to: j, now: now)
        #expect(j.state == .deferred)
        #expect(j.deferredSince == now)
        let later = now.addingTimeInterval(100_000)
        j = try JobTransitions.apply(.retryDeferred, to: j, now: later)
        #expect(j.attempts == 0 && j.state == .pending)
        for _ in 0...8 { j = try JobTransitions.apply(.itemFailure(message: "e", retryAt: later), to: j, now: later) }
        #expect(j.state == .deferred)
        #expect(j.deferredSince == now, "deferred_since is only written when NULL")
    }

    @Test func exportGaveUpDefers() throws {
        let j = try JobTransitions.apply(.exportGaveUp, to: job(), now: now)
        #expect(j.state == .deferred && j.stateReason == .exportFailures)
    }

    @Test func destinationFailureDoesNotCountAttempts() throws {
        var j = try JobTransitions.apply(.startUpload(generation: 1), to: job(), now: now)
        j = try JobTransitions.apply(.destinationFailure(message: "offline"), to: j, now: now)
        #expect(j.state == .pending)
        #expect(j.attempts == 0)
    }

    @Test func deferralExpiresExceptTooLargeForDisk() throws {
        var j = try JobTransitions.apply(.exportGaveUp, to: job(), now: now)
        j = try JobTransitions.apply(.deferralExpired, to: j, now: now)
        #expect(j.state == .skipped && j.stateReason == .deferredTooLong)
        var big = try JobTransitions.apply(.tooLargeForDisk, to: job(), now: now)
        big = try JobTransitions.apply(.deferralExpired, to: big, now: now)
        #expect(big.state == .deferred && big.stateReason == .tooLargeForDisk)
    }

    @Test func retrySkippedResetsCountersAndKeepsRemoteId() throws {
        var j = try JobTransitions.apply(.reserved(remoteId: "f1"), to: job(), now: now)
        j = try JobTransitions.apply(.permanentFailure(.permanentError, message: "x"), to: j, now: now)
        j.attempts = 5
        j = try JobTransitions.apply(.retrySkipped, to: j, now: now)
        #expect(j.state == .pending && j.attempts == 0 && j.remoteId == "f1")
    }

    @Test func retrySkippedDropsAStaleResumableSession() throws {
        var j = try JobTransitions.apply(.reserved(remoteId: "f1"), to: job(), now: now)
        j = try JobTransitions.apply(.startUpload(generation: 1), to: j, now: now)
        j = try JobTransitions.apply(.sessionStarted(SessionCheckpoint(sessionRef: "s", md5: "m", totalBytes: 1)), to: j, now: now)
        j = try JobTransitions.apply(.permanentFailure(.permanentError, message: "x"), to: j, now: now)
        #expect(j.sessionRef == "s", "a skipped job keeps what it had")
        j = try JobTransitions.apply(.retrySkipped, to: j, now: now)
        #expect(j.sessionRef == nil && j.sessionMd5 == nil && j.remoteId == "f1")
    }

    @Test func sessionDroppedClearsOnlyTheSessionAndOnlyWhileTheJobIsLive() throws {
        var j = try JobTransitions.apply(.reserved(remoteId: "f1"), to: job(), now: now)
        j = try JobTransitions.apply(.startUpload(generation: 1), to: j, now: now)
        j = try JobTransitions.apply(.sessionStarted(SessionCheckpoint(sessionRef: "s", md5: "m", totalBytes: 1)), to: j, now: now)
        let dropped = try JobTransitions.apply(.sessionDropped, to: j, now: now)
        #expect(dropped.state == .uploading && dropped.sessionRef == nil && dropped.sessionMd5 == nil)
        #expect(dropped.remoteId == "f1" && dropped.uploadingGen == 1)
        #expect(throws: JobTransitionError.self) { try JobTransitions.apply(.sessionDropped, to: job(.done, done: 1), now: now) }
    }

    @Test func doneToPendingRefreshWhenTargetRises() throws {
        var j = job(.done, target: 1, done: 1)
        j.remoteId = "f1"
        let refreshed = try JobTransitions.apply(.contentChanged(targetGen: 2), to: j, now: now)
        #expect(refreshed.state == .pending && refreshed.origin == .refresh && refreshed.remoteId == "f1")
        let same = try JobTransitions.apply(.contentChanged(targetGen: 1), to: j, now: now)
        #expect(same == j)
    }

    @Test func missingRemoteReuploadClearsIdKeepsName() throws {
        var j = job(.done, target: 1, done: 1)
        j.remoteId = "f1"
        j.remoteName = "a.HEIC"
        j.uploadedHash = "h"
        j = try JobTransitions.apply(.missingAtDestination, to: j, now: now)
        #expect(j.state == .missingRemote)
        j = try JobTransitions.apply(.reuploadConfirmed, to: j, now: now)
        #expect(j.state == .pending && j.origin == .reupload)
        #expect(j.remoteId == nil && j.uploadedHash == nil && j.remoteName == "a.HEIC")
    }

    @Test func cancelAndReinstate() throws {
        let c = try JobTransitions.apply(.cancel, to: job(), now: now)
        #expect(c.state == .cancelled)
        let r = try JobTransitions.apply(.reinstate(origin: .backfill), to: c, now: now)
        #expect(r.state == .pending && r.origin == .backfill)
        #expect(throws: JobTransitionError.self) { try JobTransitions.apply(.cancel, to: job(.done), now: now) }
    }

    @Test func cancelAllOnlyWhenEveryJobIsWaiting() {
        let waiting = [job(), job(.deferred)]
        #expect(JobTransitions.cancelAll(waiting, now: now).count == 2)
        #expect(JobTransitions.cancelAll([job(), job(.uploading)], now: now).isEmpty)
        #expect(JobTransitions.cancelAll([job(), job(.done)], now: now).isEmpty)
    }

    @Test func upsertIsIdempotentAndNeverOvershoots() throws {
        let identity = JobIdentity(destinationId: .googleDrive, assetKey: .local("A"), resType: .photo)
        let desired = JobTransitions.Desired(identity: identity, origin: .incremental, targetGen: 2)
        let created = try #require(JobTransitions.upsert(existing: nil, desired: desired, now: now))
        #expect(created.targetGen == 2 && created.state == .pending)
        #expect(JobTransitions.upsert(existing: created, desired: desired, now: now) == nil)
        #expect(JobTransitions.upsert(existing: created, desired: desired, now: now) == nil, "repeated triggers change nothing")
        var done = created
        done.state = .done
        done.doneGen = 2
        #expect(JobTransitions.upsert(existing: done, desired: desired, now: now) == nil)
        let bumped = try #require(JobTransitions.upsert(existing: done, desired: .init(identity: identity, origin: .incremental, targetGen: 3), now: now))
        #expect(bumped.targetGen == 3 && bumped.state == .pending && bumped.origin == .refresh)
        var cancelled = created
        cancelled.state = .cancelled
        let reinstated = try #require(JobTransitions.upsert(existing: cancelled, desired: desired, now: now))
        #expect(reinstated.state == .pending)
        var skipped = created
        skipped.state = .skipped
        #expect(JobTransitions.upsert(existing: skipped, desired: desired, now: now) == nil)
    }

    @Test func readinessRequiresStagedGeneration() {
        var resource = ResourceRecord(assetKey: .local("A"), type: .photo, originalFilename: "a.HEIC", uti: "public.heic", contentGen: 2)
        let j = job(target: 2)
        #expect(!JobTransitions.isReady(j, resource: resource, now: now))
        resource.stagingState = .ready
        resource.stagingGen = 1
        #expect(!JobTransitions.isReady(j, resource: resource, now: now))
        resource.stagingGen = 2
        #expect(JobTransitions.isReady(j, resource: resource, now: now))
        var later = j
        later.nextAttemptAt = now.addingTimeInterval(60)
        #expect(!JobTransitions.isReady(later, resource: resource, now: now))
    }
}
