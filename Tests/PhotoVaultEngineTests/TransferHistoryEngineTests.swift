import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// The history the engine leaves behind: a row per outcome, backfill runs, integrity results, and retries
/// that only use the owner's existing retry transitions.
@Suite struct TransferHistoryEngineTests {
    private func events(_ h: Harness) throws -> [TransferEventRow] {
        try h.read { db in try HistoryRepository.events(db, filter: TransferEventFilter(), limit: 1_000) }.reversed()
    }

    private func runs(_ h: Harness) throws -> [BackfillRunRow] {
        try h.read { db in try BackfillRunRepository.fetchAll(db) }
    }

    /// Old photos backed up by the first backfill.
    private func backedUp(_ count: Int = 2) async throws -> Harness {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        for index in 0..<count { await h.add(h.snapshot("old\(index)", daysAgo: Double(index + 2)), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.settle()
        return h
    }

    @Test func theFirstBackfillIsOneRunThatFinishes() async throws {
        let h = try await backedUp()
        let rows = try events(h)
        #expect(rows.map(\.outcome) == [.uploaded, .uploaded])
        #expect(Set(rows.map(\.fileName)) == ["IMG_old0.HEIC", "IMG_old1.HEIC"])
        #expect(rows.allSatisfy { $0.origin == .backfill && $0.bytes > 0 && !$0.approximate })
        let run = try #require(try runs(h).first)
        #expect(try runs(h).count == 1)
        #expect(run.trigger == .library && run.finishedAt != nil && run.waiting == 0)
        #expect(rows.allSatisfy { $0.runId == run.id })
        #expect(run.totals[.uploaded]?.files == 2)
    }

    @Test func aDestinationAddedLaterIsARunOfItsOwn() async throws {
        let h = try await backedUp()
        try h.addNAS(scope: .full)
        try await h.coordinator.destinationAdded(h.nasId)
        await h.settle()
        let added = try #require(try runs(h).first { $0.trigger == .destinationAdded })
        #expect(added.destinationId == h.nasId && added.finishedAt != nil)
        #expect(added.totals[.uploaded]?.files == 2)
        let nasRows = try events(h).filter { $0.destinationId == h.nasId }
        #expect(nasRows.count == 2 && nasRows.allSatisfy { $0.runId == added.id && $0.origin == .destinationBackfill })
    }

    @Test func aFailureIsOneRowAndRetryUploadsTheFileThroughTheOwnersRetry() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("a", daysAgo: 2), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.drive.failNext(.upload, with: .itemRejected(reason: "bad"), times: 9)
        for _ in 0..<9 {
            await h.run()
            h.clock.advance(by: 3600)
        }
        let failed = try #require(try events(h).last)
        #expect(failed.outcome == .failed && failed.reason == .uploadFailures && failed.detail == "itemRejected(bad)")
        let run = try #require(try runs(h).first)
        #expect(run.finishedAt != nil && run.totals[.failed]?.files == 1, "a failed file does not hold the run open")

        let identity = JobIdentity(destinationId: .googleDrive, assetKey: failed.assetKey, resType: failed.resType)
        #expect(try await h.coordinator.retryFiles([identity]) == 1)
        #expect(try runs(h).first?.finishedAt == nil, "the run waits for the retried file")
        await h.settle()
        #expect(try events(h).map(\.outcome) == [.failed, .uploaded])
        #expect(try runs(h).first?.totals[.uploaded]?.files == 1)
        #expect(try runs(h).first?.finishedAt != nil)
    }

    @Test func retryingARunOrAnUploadedFileTouchesOnlyFailedJobs() async throws {
        let h = try await Harness()
        try h.addNAS(scope: .full)
        await h.add(h.snapshot("a", daysAgo: 2), recordChange: false)
        await h.add(h.snapshot("b", daysAgo: 3), recordChange: false)
        try await h.baseline(h.nasId)
        await h.nas.failNext(.upload, with: .foreignFile)
        await h.settle()
        #expect(Set(try events(h).map(\.outcome)) == [.uploaded, .skipped])
        let skipped = try #require(try events(h).first { $0.outcome == .skipped })
        #expect(skipped.reason == .foreignFile)
        let uploaded = try #require(try events(h).first { $0.outcome == .uploaded })
        #expect(try await h.coordinator.retryFiles([JobIdentity(destinationId: h.nasId, assetKey: uploaded.assetKey, resType: .photo)]) == 0)
        let run = try #require(skipped.runId)
        #expect(try await h.coordinator.retryFailedFiles(ofRun: run) == 1)
        await h.settle()
        #expect(try h.jobs().allSatisfy { $0.state == .done })
        #expect(await h.nas.files.count == 2)
    }

    @Test func retryingAFileTooLargeForTheDiskReArmsItAtEveryDestination() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try h.addNAS(scope: .full)
        await h.add(h.snapshot("big", daysAgo: 2), recordChange: false)
        try await h.baseline(.googleDrive, h.nasId)
        await h.drive.setStatus(.unavailable(.offline))
        await h.nas.setStatus(.unavailable(.offline))
        await h.run()
        let jobs = try h.jobs().filter { !$0.resType.isSidecar }
        #expect(jobs.count == 2)
        let now = h.clock.now
        try h.write { db in
            for job in jobs { _ = try JobRepository.apply(db, .tooLargeForDisk, to: job.identity, now: now) }
            try db.execute(sql: "UPDATE resource SET too_large_for_disk = 1")
        }
        let drive = try #require(jobs.first { $0.destinationId == .googleDrive })
        #expect(try await h.coordinator.retryFiles([drive.identity]) == 1)
        #expect(try h.jobs().filter { !$0.resType.isSidecar }.allSatisfy { $0.state == .pending }, "the NAS job waited for the same mark")
        #expect(try h.read { db in try Int.fetchOne(db, sql: "SELECT SUM(too_large_for_disk) FROM resource") } == 0)
    }

    @Test func narrowingTheScopeRecordsTheCancelledFiles() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("a", daysAgo: 2), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.drive.setStatus(.unavailable(.offline))
        await h.run()
        try h.updateDestination(.googleDrive) { $0.scope = .newOnly }
        try await h.coordinator.destinationRulesChanged(.googleDrive)
        #expect(try events(h).map(\.outcome) == [.cancelled])
    }

    @Test func aCrashBetweenTheUploadAndItsCommitLeavesNoRowAndTheRecoveryRecordsOne() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("a", daysAgo: 2), recordChange: false)
        try await h.baseline(.googleDrive)
        h.injector.arm(.afterUploadBeforeCommit)
        await h.run()
        #expect(h.injector.visited.contains(.afterUploadBeforeCommit))
        #expect(try h.jobs().first?.state == .uploading)
        #expect(try events(h).isEmpty)
        h.injector.arm(nil)
        try await h.restart()
        try await h.coordinator.start()
        await h.settle()
        #expect(try events(h).map(\.outcome) == [.uploaded])
        #expect(await h.drive.files.count == 1)
    }

    @Test func anIntegrityCheckRecordsEachFilesResult() async throws {
        let h = try await Harness()
        let (_, root, _) = try await h.useRealLocal()
        try h.addNAS(scope: .full)
        for index in 0..<3 { await h.add(h.snapshot("q\(index)", daysAgo: Double(index + 1)), recordChange: false) }
        try await h.baseline(h.nasId)
        await h.settle()
        let files = treeListing(root).keys.filter { !$0.hasPrefix(".photovault") }.sorted()
        try FileManager.default.removeItem(at: root.appendingPathComponent(files[0]))
        try Data("x".utf8).write(to: root.appendingPathComponent(files[1]))
        _ = try await h.coordinator.runIntegrityCheck(h.nasId)
        let jobs = try h.jobs().filter { !$0.resType.isSidecar }
        let results = try h.read { db in try jobs.compactMap { try IntegrityCheckRepository.fetch(db, identity: $0.identity)?.result } }
        #expect(results.count == 3)
        #expect(results.filter { $0 == .missing }.count == 1)
        #expect(results.filter { $0 == .sizeMismatch }.count == 1)
        #expect(results.filter { $0 == .intact || $0 == .hashVerified }.count == 1)
    }

    @Test func historyNeverPutsAFileNameInTheLogOrTheActivityList() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("Secret-Đà-Lạt", daysAgo: 2), recordChange: false)
        await h.add(h.snapshot("Private-Beach", daysAgo: 3), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.drive.failNext(.upload, with: .itemRejected(reason: "bad"), times: 18)
        for _ in 0..<12 {
            await h.run()
            h.clock.advance(by: 3600)
        }
        let failed = try events(h).filter { $0.outcome == .failed }
        #expect(!failed.isEmpty)
        _ = try await h.coordinator.retryFiles(failed.map { JobIdentity(destinationId: $0.destinationId, assetKey: $0.assetKey, resType: $0.resType) })
        await h.settle()
        _ = try await h.coordinator.runIntegrityCheck(.googleDrive)
        #expect(try events(h).contains { $0.fileName.contains("Secret") }, "the history itself has the name")
        let activity = try h.read { db in try ActivityRepository.recent(db) }.map(\.message)
        for text in h.log.lines + activity {
            #expect(!text.contains("Secret") && !text.contains("Private") && !text.contains("IMG_"), "\(text)")
        }
    }
}
