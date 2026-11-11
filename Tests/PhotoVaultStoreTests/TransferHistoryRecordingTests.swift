import Foundation
import GRDB
import PhotoVaultCore
import Testing
@testable import PhotoVaultStore

/// Made-up library used by the history tests.
enum HistoryFixture {
    static let drive = DestinationID.googleDrive

    static func identity(_ key: AssetKey, _ type: ResourceType = .photo, _ dest: DestinationID = drive) -> JobIdentity {
        JobIdentity(destinationId: dest, assetKey: key, resType: type)
    }

    /// An asset with one resource of `size` bytes.
    @discardableResult
    static func file(
        _ db: Database, _ id: String, name: String = "IMG_0001.HEIC", size: Int64 = 1_000, type: ResourceType = .photo,
        media: MediaType = .image, raw: Bool = false, created: Date = t0, deleted: Date? = nil, source: SourceID = .photos
    ) throws -> AssetKey {
        let key = AssetKey.local(id)
        try AssetRepository.upsert(db, AssetRecord(
            assetKey: key, localId: id, creationDate: created, mediaType: media, category: .camera, firstSeenAt: t0, lastSeenAt: t0,
            deletedAt: deleted, sourceId: source), timeZone: utc)
        try ResourceRepository.upsert(db, ResourceRecord(
            assetKey: key, type: type, isRaw: raw, originalFilename: name, uti: "public.heic", sizeBytes: size))
        return key
    }

    static func upload(_ db: Database, _ identity: JobIdentity, at: Date, generation: Int = 1) throws {
        _ = try JobRepository.apply(db, .startUpload(generation: generation), to: identity, now: at)
        _ = try JobRepository.apply(
            db, .uploadSucceeded(remoteId: "r-\(identity.assetKey.rawValue)", finalName: "n", parent: "p", verifiedHash: "h"),
            to: identity, now: at)
    }

    static func failForGood(_ db: Database, _ identity: JobIdentity, at: Date) throws {
        for _ in 0...JobTransitions.maxAttempts {
            _ = try JobRepository.apply(db, .itemFailure(message: "server(503)", retryAt: at), to: identity, now: at)
        }
    }

    static func events(_ db: Database) throws -> [Row] {
        try Row.fetchAll(db, sql: "SELECT * FROM transfer_event ORDER BY id")
    }

    static func outcomes(_ db: Database) throws -> [String] { try events(db).map { $0["outcome"] } }
}

@Suite struct TransferHistoryRecordingTests {
    typealias F = HistoryFixture

    @Test func anUploadIsOneRowWithTheFileSizeAndOrigin() throws {
        let store = try Store.inMemory()
        try store.write { db in
            let key = try F.file(db, "a", size: 4_321)
            try JobRepository.upsert(db, desired: desired(F.drive, key), now: t0)
            try F.upload(db, F.identity(key), at: t0.addingTimeInterval(60))
            let rows = try F.events(db)
            #expect(rows.count == 1)
            #expect(rows.first?["outcome"] == "uploaded")
            #expect(rows.first?["bytes"] == 4_321)
            #expect(rows.first?["origin"] == "incremental")
            #expect(rows.first?["source_id"] == "photos")
            #expect((rows.first?["at"] as Date?) == t0.addingTimeInterval(60))
            #expect(rows.first?["approximate"] == false)
        }
    }

    @Test func anEditThatReplacesTheFileIsAnUpdate() throws {
        let store = try Store.inMemory()
        try store.write { db in
            let key = try F.file(db, "a")
            try JobRepository.upsert(db, desired: desired(F.drive, key), now: t0)
            try F.upload(db, F.identity(key), at: t0)
            try JobRepository.upsert(db, desired: desired(F.drive, key, gen: 2), now: t0)
            try F.upload(db, F.identity(key), at: t0, generation: 2)
            #expect(try F.outcomes(db) == ["uploaded", "updated"])
            #expect(try F.events(db).last?["origin"] == "refresh")
        }
    }

    @Test func anUploadOvertakenByANewerEditIsStillRecordedOnce() throws {
        let store = try Store.inMemory()
        try store.write { db in
            let key = try F.file(db, "a")
            try JobRepository.upsert(db, desired: desired(F.drive, key, origin: .backfill), now: t0)
            _ = try JobRepository.apply(db, .startUpload(generation: 1), to: F.identity(key), now: t0)
            _ = try JobRepository.apply(db, .contentChanged(targetGen: 2), to: F.identity(key), now: t0)
            _ = try JobRepository.apply(db, .uploadSucceeded(remoteId: "r", finalName: "n", parent: "p", verifiedHash: "h"), to: F.identity(key), now: t0)
            #expect(try JobRepository.fetch(db, identity: F.identity(key))?.state == .pending)
            let rows = try F.events(db)
            #expect(rows.map { $0["outcome"] as String } == ["uploaded"])
            #expect(rows.first?["origin"] == "backfill")
            #expect(rows.first?["run_id"] as Int64? != nil)
        }
    }

    @Test func aGiveUpIsOneFailedRowAndTheSameFailureIsNotRepeated() throws {
        let store = try Store.inMemory()
        try store.write { db in
            let key = try F.file(db, "a")
            try JobRepository.upsert(db, desired: desired(F.drive, key), now: t0)
            try F.failForGood(db, F.identity(key), at: t0)
            let first = try F.events(db)
            #expect(first.map { $0["outcome"] as String } == ["failed"])
            #expect(first.first?["reason"] == "uploadFailures")
            #expect(first.first?["detail"] == "server(503)")
            // Retried after a day and failing the same way: no new row.
            _ = try JobRepository.apply(db, .retryDeferred, to: F.identity(key), now: t0)
            try F.failForGood(db, F.identity(key), at: t0)
            #expect(try F.outcomes(db) == ["failed"])
            // Another reason is news.
            _ = try JobRepository.apply(db, .retryDeferred, to: F.identity(key), now: t0)
            _ = try JobRepository.apply(db, .exportGaveUp, to: F.identity(key), now: t0)
            #expect(try F.outcomes(db) == ["failed", "failed"])
            // After a success, a new failure is recorded again.
            _ = try JobRepository.apply(db, .retryDeferred, to: F.identity(key), now: t0)
            try F.upload(db, F.identity(key), at: t0)
            try JobRepository.upsert(db, desired: desired(F.drive, key, gen: 2), now: t0)
            _ = try JobRepository.apply(db, .exportGaveUp, to: F.identity(key), now: t0)
            #expect(try F.outcomes(db) == ["failed", "failed", "uploaded", "failed"])
        }
    }

    @Test func skipsAndCancelsAreRecordedWithTheirReason() throws {
        let store = try Store.inMemory()
        try store.write { db in
            let skipped = try F.file(db, "a")
            let cancelled = try F.file(db, "b")
            try JobRepository.upsert(db, desired: desired(F.drive, skipped), now: t0)
            try JobRepository.upsert(db, desired: desired(F.drive, cancelled), now: t0)
            _ = try JobRepository.apply(db, .permanentFailure(.foreignFile, message: "foreignFile"), to: F.identity(skipped), now: t0)
            _ = try JobRepository.apply(db, .cancel, to: F.identity(cancelled), now: t0)
            let rows = try F.events(db)
            #expect(rows.map { $0["outcome"] as String } == ["skipped", "cancelled"])
            #expect(rows.first?["reason"] == "foreignFile")
            #expect(rows.last?["reason"] as String? == nil)
        }
    }

    @Test func progressSidecarsAndRecoveredFilesWriteNothing() throws {
        let store = try Store.inMemory()
        try store.write { db in
            let key = try F.file(db, "a")
            try JobRepository.upsert(db, desired: desired(F.drive, key), now: t0)
            _ = try JobRepository.apply(db, .reserved(remoteId: "r"), to: F.identity(key), now: t0)
            _ = try JobRepository.apply(db, .startUpload(generation: 1), to: F.identity(key), now: t0)
            _ = try JobRepository.apply(db, .itemFailure(message: "offline", retryAt: t0), to: F.identity(key), now: t0)
            let sidecar = F.identity(key, .sidecarJson)
            try JobRepository.upsert(db, desired: desired(F.drive, key, .sidecarJson), now: t0)
            try F.upload(db, sidecar, at: t0)
            // Recovery writes a matched file as done without an upload.
            let recovered = try F.file(db, "b")
            try JobRepository.upsert(db, desired: desired(F.drive, recovered), now: t0)
            var job = try #require(try JobRepository.fetch(db, identity: F.identity(recovered)))
            job.state = .done
            job.doneGen = 1
            try JobRepository.save(db, &job)
            #expect(try F.events(db).isEmpty)
        }
    }

    @Test func aRolledBackStateChangeLeavesNoRow() throws {
        struct Abort: Error {}
        let store = try Store.inMemory()
        let key = try store.write { db in
            let key = try F.file(db, "a")
            try JobRepository.upsert(db, desired: desired(F.drive, key), now: t0)
            _ = try JobRepository.apply(db, .startUpload(generation: 1), to: F.identity(key), now: t0)
            return key
        }
        #expect(throws: Abort.self) {
            try store.write { db in
                _ = try JobRepository.apply(db, .uploadSucceeded(remoteId: "r", finalName: "n", parent: "p", verifiedHash: "h"), to: F.identity(key), now: t0)
                #expect(try F.events(db).count == 1)
                throw Abort()
            }
        }
        let after = try store.read { db in (try JobRepository.fetch(db, identity: F.identity(key))?.state, try F.events(db)) }
        #expect(after.0 == .uploading)
        #expect(after.1.isEmpty)
    }

    @Test func theEventKeepsTheImportItCameFrom() throws {
        let store = try Store.inMemory()
        let source = SourceID.folder()
        try store.write { db in
            let key = try F.file(db, "a", source: source)
            try JobRepository.upsert(db, desired: desired(F.drive, key), now: t0)
            try F.upload(db, F.identity(key), at: t0)
            #expect(try F.events(db).first?["source_id"] == source.rawValue)
        }
    }

    @Test func aReUploadOfAMissingFileClearsItsMissingResult() throws {
        let store = try Store.inMemory()
        let after = try store.write { db -> (IntegrityCheckResult?, IntegrityCheckResult?) in
            let key = try F.file(db, "a")
            try JobRepository.upsert(db, desired: desired(F.drive, key), now: t0)
            try F.upload(db, F.identity(key), at: t0)
            _ = try JobRepository.apply(db, .missingAtDestination, to: F.identity(key), now: t0)
            try IntegrityCheckRepository.record(db, identity: F.identity(key), result: .missing, at: t0)
            _ = try JobRepository.apply(db, .reuploadConfirmed, to: F.identity(key), now: t0)
            let waiting = try IntegrityCheckRepository.fetch(db, identity: F.identity(key))?.result
            try F.upload(db, F.identity(key), at: t0.addingTimeInterval(60))
            return (waiting, try IntegrityCheckRepository.fetch(db, identity: F.identity(key))?.result)
        }
        #expect(after.0 == .missing, "still missing until the new copy is up")
        #expect(after.1 == nil, "the new copy has not been checked")
    }

    @Test func anEditedFileDropsTheCheckOfItsOlderContent() throws {
        let store = try Store.inMemory()
        let after = try store.write { db -> (IntegrityCheckResult?, IntegrityCheckResult?, [String]) in
            let key = try F.file(db, "a")
            let other = try F.file(db, "b")
            for item in [key, other] {
                try JobRepository.upsert(db, desired: desired(F.drive, item), now: t0)
                try F.upload(db, F.identity(item), at: t0)
                try IntegrityCheckRepository.record(db, identity: F.identity(item), result: .hashVerified, at: t0)
            }
            _ = try JobRepository.apply(db, .contentChanged(targetGen: 2), to: F.identity(key), now: t0)
            try F.upload(db, F.identity(key), at: t0.addingTimeInterval(60), generation: 2)
            return (
                try IntegrityCheckRepository.fetch(db, identity: F.identity(key))?.result,
                try IntegrityCheckRepository.fetch(db, identity: F.identity(other))?.result, try F.outcomes(db))
        }
        #expect(after.0 == nil)
        #expect(after.1 == .hashVerified, "only the uploaded file's result goes")
        #expect(after.2.last == "updated")
    }

    @Test func aFailureOrACancelKeepsTheLastCheck() throws {
        let store = try Store.inMemory()
        let kept = try store.write { db -> [IntegrityCheckResult?] in
            let failing = try F.file(db, "failing")
            let cancelled = try F.file(db, "cancelled")
            for key in [failing, cancelled] {
                try JobRepository.upsert(db, desired: desired(F.drive, key), now: t0)
                try F.upload(db, F.identity(key), at: t0)
                try IntegrityCheckRepository.record(db, identity: F.identity(key), result: .hashVerified, at: t0)
                _ = try JobRepository.apply(db, .contentChanged(targetGen: 2), to: F.identity(key), now: t0)
            }
            try F.failForGood(db, F.identity(failing), at: t0.addingTimeInterval(10))
            _ = try JobRepository.apply(db, .cancel, to: F.identity(cancelled), now: t0.addingTimeInterval(20))
            #expect(try F.outcomes(db).suffix(2) == ["failed", "cancelled"])
            return try [failing, cancelled].map { try IntegrityCheckRepository.fetch(db, identity: F.identity($0))?.result }
        }
        #expect(kept == [.hashVerified, .hashVerified], "the copy that was checked is still the one at the destination")
    }
}
