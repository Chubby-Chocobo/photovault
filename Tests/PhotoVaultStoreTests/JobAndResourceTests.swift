import Foundation
import GRDB
import PhotoVaultCore
import Testing
@testable import PhotoVaultStore

@Suite struct JobTests {
    let drive = DestinationID.googleDrive

    private func identity(_ key: AssetKey, _ type: ResourceType = .photo, _ dest: DestinationID = .googleDrive) -> JobIdentity {
        JobIdentity(destinationId: dest, assetKey: key, resType: type)
    }

    @Test func doneJobWithUnchangedContentDoesNotChange() throws {
        let store = try Store.inMemory()
        try store.write { db in
            let key = AssetKey.local("1")
            try JobRepository.upsert(db, desired: desired(drive, key), now: t0)
            _ = try JobRepository.apply(db, .startUpload(generation: 1), to: identity(key), now: t0)
            _ = try JobRepository.apply(db, .uploadSucceeded(remoteId: "r", finalName: "n", parent: "p", verifiedHash: "h"), to: identity(key), now: t0)
            let before = try #require(try JobRepository.fetch(db, identity: identity(key)))
            #expect(before.state == .done)

            #expect(try JobRepository.upsert(db, desired: desired(drive, key), now: t0.addingTimeInterval(10)) == nil)
            #expect(try JobRepository.fetch(db, identity: identity(key)) == before)
        }
    }

    @Test func changedContentRaisesTargetGenAndRefreshes() throws {
        let store = try Store.inMemory()
        try store.write { db in
            let key = AssetKey.local("1")
            try JobRepository.upsert(db, desired: desired(drive, key), now: t0)
            _ = try JobRepository.apply(db, .startUpload(generation: 1), to: identity(key), now: t0)
            _ = try JobRepository.apply(db, .uploadSucceeded(remoteId: "r", finalName: "n", parent: "p", verifiedHash: "h"), to: identity(key), now: t0)
            let updated = try #require(try JobRepository.upsert(db, desired: desired(drive, key, gen: 2), now: t0))
            #expect(updated.targetGen == 2 && updated.doneGen == 1 && updated.state == .pending)
            #expect(updated.remoteId == "r" && updated.origin == .refresh)
        }
    }

    @Test func updateWhileUploadingOnlyRaisesTargetGen() throws {
        let store = try Store.inMemory()
        try store.write { db in
            let key = AssetKey.local("1")
            try JobRepository.upsert(db, desired: desired(drive, key), now: t0)
            _ = try JobRepository.apply(db, .startUpload(generation: 1), to: identity(key), now: t0)
            let job = try #require(try JobRepository.upsert(db, desired: desired(drive, key, gen: 3), now: t0))
            #expect(job.state == .uploading && job.targetGen == 3 && job.uploadingGen == 1)
            let finished = try JobRepository.apply(
                db, .uploadSucceeded(remoteId: "r", finalName: "n", parent: "p", verifiedHash: "h"), to: identity(key), now: t0)
            #expect(finished.state == .pending && finished.doneGen == 1)
        }
    }

    @Test func cancelAndReinstate() throws {
        let store = try Store.inMemory()
        try store.write { db in
            let key = AssetKey.local("1")
            try JobRepository.upsert(db, desired: desired(drive, key), now: t0)
            try JobRepository.upsert(db, desired: desired(drive, key, .sidecarJson), now: t0)
            let cancelled = try JobRepository.cancelAll(db, assetKey: key, destinationId: drive, now: t0)
            #expect(cancelled.count == 2 && cancelled.allSatisfy { $0.state == .cancelled })
            let back = try #require(try JobRepository.upsert(db, desired: desired(drive, key, origin: .backfill), now: t0))
            #expect(back.state == .pending && back.origin == .backfill)
        }
    }

    @Test func skippedJobStaysSkippedOnUpsert() throws {
        let store = try Store.inMemory()
        try store.write { db in
            let key = AssetKey.local("1")
            try JobRepository.upsert(db, desired: desired(drive, key), now: t0)
            _ = try JobRepository.apply(db, .permanentFailure(.permanentError, message: "x"), to: identity(key), now: t0)
            #expect(try JobRepository.upsert(db, desired: desired(drive, key, gen: 2), now: t0) == nil)
        }
    }

    @Test func invalidTransitionThrowsAndKeepsRow() throws {
        let store = try Store.inMemory()
        try store.write { db in
            let key = AssetKey.local("1")
            try JobRepository.upsert(db, desired: desired(drive, key), now: t0)
            #expect(throws: JobTransitionError.self) {
                try JobRepository.apply(db, .checksumMismatch, to: identity(key), now: t0)
            }
            #expect(throws: StoreError.self) {
                try JobRepository.apply(db, .cancel, to: identity(.local("none")), now: t0)
            }
            #expect(try JobRepository.fetch(db, identity: identity(key))?.state == .pending)
        }
    }

    @Test func sessionRefRoundTripsButNeverReachesActivity() throws {
        let store = try Store.inMemory()
        try store.write { db in
            let key = AssetKey.local("1")
            try JobRepository.upsert(db, desired: desired(drive, key), now: t0)
            _ = try JobRepository.apply(db, .startUpload(generation: 1), to: identity(key), now: t0)
            _ = try JobRepository.apply(db, .sessionStarted(SessionCheckpoint(sessionRef: "https://secret-session", md5: "m", totalBytes: 10)), to: identity(key), now: t0)
            #expect(try JobRepository.fetch(db, identity: identity(key))?.sessionRef == "https://secret-session")
            try ActivityRepository.record(db, ActivityEvent(at: t0, kind: .notice, destinationId: drive, assetKey: key, message: "ok"))
            let dump = try String.fetchAll(db, sql: "SELECT message || ifnull(asset_key,'') FROM activity").joined()
            #expect(!dump.contains("secret-session"))
        }
    }

    @Test func readyQueryFiltersAndOrders() throws {
        let store = try Store.inMemory()
        let old = t0.addingTimeInterval(-86_400 * 10)
        let new = t0
        try store.write { db in
            func add(_ id: String, created: Date, origin: JobOrigin, resource: StagingState?, stagingGen: Int = 1, gen: Int = 1, type: ResourceType = .photo) throws {
                try AssetRepository.upsert(db, makeAsset(id, created: created), timeZone: utc)
                if let resource { try ResourceRepository.upsert(db, makeResource(.local(id), type, state: resource, stagingGen: stagingGen)) }
                try JobRepository.upsert(db, desired: desired(drive, .local(id), type, origin: origin, gen: gen), now: t0)
            }
            try add("backfillNew", created: new, origin: .backfill, resource: .ready)
            try add("backfillOld", created: old, origin: .backfill, resource: .ready)
            try add("incrementalOld", created: old, origin: .incremental, resource: .ready)
            try add("refresh", created: old, origin: .refresh, resource: .ready)
            try add("notReady", created: new, origin: .incremental, resource: .exporting)
            try add("staleStaging", created: new, origin: .incremental, resource: .ready, stagingGen: 1, gen: 2)
            try add("noResource", created: new, origin: .incremental, resource: nil)
            try add("sidecar", created: old, origin: .backfill, resource: nil, type: .sidecarJson)
            try add("backoff", created: new, origin: .incremental, resource: .ready)
            _ = try JobRepository.apply(
                db, .itemFailure(message: "e", retryAt: t0.addingTimeInterval(60)),
                to: identity(.local("backoff")), now: t0)

            let ready = try JobRepository.readyToUpload(db, destinationId: drive, now: t0, limit: 50)
            #expect(ready.map(\.job.assetKey.identifier) == ["incrementalOld", "refresh", "backfillNew", "backfillOld", "sidecar"])
            #expect(ready.last?.resource == nil)

            let later = try JobRepository.readyToUpload(db, destinationId: drive, now: t0.addingTimeInterval(61), limit: 2)
            #expect(later.map(\.job.assetKey.identifier) == ["backoff", "incrementalOld"])
            #expect(try JobRepository.readyToUpload(db, destinationId: .local(), now: t0, limit: 5).isEmpty)
        }
    }
}

@Suite struct ResourceTests {
    @Test func stagingStateMachine() throws {
        let store = try Store.inMemory()
        let key = AssetKey.local("1")
        try store.write { db in
            try ResourceRepository.upsert(db, makeResource(key))
            #expect(try ResourceRepository.completeExport(db, key: key, type: .photo, path: "p", sizeBytes: 1, md5: nil, sha256: nil, now: t0) == false)
            #expect(try ResourceRepository.beginExport(db, key: key, type: .photo, generation: 1))
            #expect(try ResourceRepository.beginExport(db, key: key, type: .photo, generation: 1) == false)
            #expect(try ResourceRepository.completeExport(db, key: key, type: .photo, path: "/s/1.1", sizeBytes: 10, md5: "m", sha256: "s", now: t0))
            var r = try #require(try ResourceRepository.fetch(db, key: key, type: .photo))
            #expect(r.stagingState == .ready && r.stagingGen == 1 && r.exportCount == 1 && r.isReadyForCurrentContent)
            #expect(try ResourceRepository.releaseStaging(db, key: key, type: .photo))
            r = try #require(try ResourceRepository.fetch(db, key: key, type: .photo))
            #expect(r.stagingState == .none && r.stagingPath == nil && r.md5 == "m")
        }
    }

    @Test func exportFailureCountsAndBacksOff() throws {
        let store = try Store.inMemory()
        let key = AssetKey.local("1")
        try store.write { db in
            try ResourceRepository.upsert(db, makeResource(key))
            try ResourceRepository.beginExport(db, key: key, type: .photo, generation: 1)
            #expect(try ResourceRepository.failExport(db, key: key, type: .photo, message: "e", retryAt: t0.addingTimeInterval(5), now: t0) == 1)
            try ResourceRepository.beginExport(db, key: key, type: .photo, generation: 1)
            #expect(try ResourceRepository.failExport(db, key: key, type: .photo, message: "e", retryAt: t0.addingTimeInterval(9), now: t0.addingTimeInterval(1)) == 2)
            let r = try #require(try ResourceRepository.fetch(db, key: key, type: .photo))
            #expect(r.exportDeferredSince == t0 && r.nextExportAttemptAt == t0.addingTimeInterval(9) && r.lastError == "e")
            #expect(try ResourceRepository.failExport(db, key: key, type: .photo, message: "e", retryAt: t0, now: t0) == nil)
        }
    }

    @Test func diskCancelAndStartupReset() throws {
        let store = try Store.inMemory()
        let key = AssetKey.local("1")
        try store.write { db in
            try ResourceRepository.upsert(db, makeResource(key))
            try ResourceRepository.beginExport(db, key: key, type: .photo, generation: 1)
            #expect(try ResourceRepository.cancelExportForDisk(db, key: key, type: .photo, bytesReceived: 100, tooLarge: true))
            var r = try #require(try ResourceRepository.fetch(db, key: key, type: .photo))
            #expect(r.bytesReceivedAtCancel == 100 && r.diskCancelCount == 1 && r.tooLargeForDisk)
            try ResourceRepository.beginExport(db, key: key, type: .photo, generation: 2)
            #expect(try ResourceRepository.resetExportingOnStartup(db) == 1)
            r = try #require(try ResourceRepository.fetch(db, key: key, type: .photo))
            #expect(r.stagingState == .none)
        }
    }

    @Test func contentGenOnlyMovesForward() throws {
        let store = try Store.inMemory()
        let key = AssetKey.local("1")
        try store.write { db in
            var r = makeResource(key)
            r.contentGen = 3
            try ResourceRepository.upsert(db, r)
            r.contentGen = 1
            try ResourceRepository.upsert(db, r)
            #expect(try ResourceRepository.fetch(db, key: key, type: .photo)?.contentGen == 3)
            #expect(try ResourceRepository.bumpContentGen(db, key: key, type: .photo) == 4)
            #expect(try ResourceRepository.fetchAll(db, key: key).count == 1)
        }
    }
}
