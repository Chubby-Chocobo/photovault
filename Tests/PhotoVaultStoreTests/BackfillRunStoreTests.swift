import Foundation
import GRDB
import PhotoVaultCore
import Testing
@testable import PhotoVaultStore

@Suite struct BackfillRunStoreTests {
    typealias F = HistoryFixture
    let nas = DestinationID.local()

    private func runIds(_ db: Database) throws -> [Int64?] {
        try Row.fetchAll(db, sql: "SELECT backfill_run_id FROM upload_job ORDER BY id").map { $0["backfill_run_id"] }
    }

    @Test func backfillJobsOfOneCauseShareARunAndOtherJobsHaveNone() throws {
        let store = try Store.inMemory()
        try store.write { db in
            let a = try F.file(db, "a"), b = try F.file(db, "b"), c = try F.file(db, "c")
            try JobRepository.upsert(db, desired: desired(F.drive, a, origin: .backfill), now: t0)
            try JobRepository.upsert(db, desired: desired(nas, b, origin: .backfill), now: t0)
            try JobRepository.upsert(db, desired: desired(F.drive, c, origin: .incremental), now: t0)
            try JobRepository.upsert(db, desired: desired(F.drive, a, .sidecarJson, origin: .backfill), now: t0)
            let ids = try runIds(db)
            #expect(ids[0] != nil && ids[0] == ids[1])
            #expect(ids[2] == nil && ids[3] == nil)
            let run = try #require(try BackfillRunRepository.fetchAll(db).first)
            #expect(run.trigger == .library && run.destinationId == nil && run.startedAt == t0)
        }
    }

    @Test func aDestinationAddedHasItsOwnRunAndAClosedRunTakesNoMoreJobs() throws {
        let store = try Store.inMemory()
        try store.write { db in
            let a = try F.file(db, "a"), b = try F.file(db, "b"), c = try F.file(db, "c")
            try JobRepository.upsert(db, desired: desired(F.drive, a, origin: .backfill), now: t0)
            try JobRepository.upsert(db, desired: desired(nas, a, origin: .destinationBackfill), now: t0, runTrigger: .destinationAdded)
            try BackfillRunRepository.close(db, trigger: .library, destinationId: nil, now: t0)
            try JobRepository.upsert(db, desired: desired(F.drive, b, origin: .backfill), now: t0, runTrigger: .settings)
            try JobRepository.upsert(db, desired: desired(F.drive, c, origin: .backfill), now: t0)
            let ids = try runIds(db).compactMap { $0 }
            #expect(Set(ids).count == 4)
            let runs = try BackfillRunRepository.fetchAll(db)
            #expect(runs.first { $0.trigger == .destinationAdded }?.destinationId == nas)
            #expect(runs.filter { $0.trigger == .library }.count == 2)
        }
    }

    @Test func aReinstatedBackfillJobJoinsTheOpenRun() throws {
        let store = try Store.inMemory()
        try store.write { db in
            let a = try F.file(db, "a")
            try JobRepository.upsert(db, desired: desired(F.drive, a, origin: .backfill), now: t0)
            _ = try JobRepository.apply(db, .cancel, to: F.identity(a), now: t0)
            try BackfillRunRepository.close(db, trigger: .settings, destinationId: nil, now: t0)
            try JobRepository.upsert(db, desired: desired(F.drive, a, origin: .backfill), now: t0, runTrigger: .settings)
            let run = try #require(try JobRepository.fetch(db, identity: F.identity(a))?.backfillRunId)
            #expect(try BackfillRunRepository.fetchAll(db).first { $0.id == run }?.trigger == .settings)
        }
    }

    @Test func aRunFinishesWhenNothingOfItWaitsAndRetryReopensIt() throws {
        let store = try Store.inMemory()
        try store.write { db in
            let a = try F.file(db, "a", size: 10), b = try F.file(db, "b", size: 20)
            try JobRepository.upsert(db, desired: desired(F.drive, a, origin: .backfill), now: t0)
            try JobRepository.upsert(db, desired: desired(F.drive, b, origin: .backfill), now: t0)
            try F.upload(db, F.identity(a), at: t0.addingTimeInterval(10))
            #expect(try BackfillRunRepository.finishSettled(db, now: t0.addingTimeInterval(99)) == 0)
            try F.failForGood(db, F.identity(b), at: t0.addingTimeInterval(20))
            #expect(try BackfillRunRepository.finishSettled(db, now: t0.addingTimeInterval(99)) == 1)
            var run = try #require(try BackfillRunRepository.fetchAll(db).first)
            #expect(run.finishedAt == t0.addingTimeInterval(20))
            #expect(run.totals[.uploaded] == OutcomeTotal(files: 1, bytes: 10))
            #expect(run.totals[.failed] == OutcomeTotal(files: 1, bytes: 20))
            #expect(run.waiting == 0)

            try BackfillRunRepository.reopen(db, runIds: [run.id])
            _ = try JobRepository.apply(db, .retryDeferred, to: F.identity(b), now: t0)
            run = try #require(try BackfillRunRepository.fetchAll(db).first)
            #expect(run.finishedAt == nil && run.waiting == 1)
            try F.upload(db, F.identity(b), at: t0.addingTimeInterval(30))
            try BackfillRunRepository.finishSettled(db, now: t0.addingTimeInterval(99))
            run = try #require(try BackfillRunRepository.fetchAll(db).first)
            // The latest outcome counts: the retried file is uploaded now.
            #expect(run.totals[.uploaded] == OutcomeTotal(files: 2, bytes: 30))
            #expect(run.totals[.failed] == nil)
            #expect(run.finishedAt == t0.addingTimeInterval(30))
        }
    }

    @Test func aFinishedRunIsClosedSoLaterJobsStartANewOne() throws {
        let store = try Store.inMemory()
        try store.write { db in
            let a = try F.file(db, "a"), b = try F.file(db, "b")
            try JobRepository.upsert(db, desired: desired(F.drive, a, origin: .backfill), now: t0)
            try F.upload(db, F.identity(a), at: t0)
            try BackfillRunRepository.finishSettled(db, now: t0)
            try JobRepository.upsert(db, desired: desired(F.drive, b, origin: .backfill), now: t0)
            #expect(Set(try runIds(db).compactMap { $0 }).count == 2)
        }
    }

    @Test func anEditAfterTheBackfillDoesNotHoldItsRunAndRetryAllFindsItsFailures() throws {
        let store = try Store.inMemory()
        try store.write { db in
            let a = try F.file(db, "a"), b = try F.file(db, "b")
            try JobRepository.upsert(db, desired: desired(F.drive, a, origin: .backfill), now: t0)
            try JobRepository.upsert(db, desired: desired(F.drive, b, origin: .backfill), now: t0)
            try F.upload(db, F.identity(a), at: t0)
            _ = try JobRepository.apply(db, .permanentFailure(.foreignFile, message: "foreignFile"), to: F.identity(b), now: t0)
            // The photo is edited: its job is pending again, as a refresh.
            try JobRepository.upsert(db, desired: desired(F.drive, a, gen: 2), now: t0)
            #expect(try BackfillRunRepository.finishSettled(db, now: t0) == 1)
            let run = try #require(try BackfillRunRepository.fetchAll(db).first)
            #expect(run.waiting == 0)
            #expect(try BackfillRunRepository.failedJobs(db, runId: run.id) == [F.identity(b)])
        }
    }

    @Test func aRunRetriedOutsideHistoryIsRunningAgainAndOneWhoseJobsWentAwayFinishes() throws {
        let store = try Store.inMemory()
        try store.write { db in
            let a = try F.file(db, "a")
            try JobRepository.upsert(db, desired: desired(F.drive, a, origin: .backfill), now: t0)
            try F.failForGood(db, F.identity(a), at: t0)
            try BackfillRunRepository.finishSettled(db, now: t0)
            var run = try #require(try BackfillRunRepository.fetchAll(db).first)
            #expect(run.finishedAt != nil && run.retryable == 1)
            // The 24-hour sweeper retries it: the run shows as running at once and is reopened by the next drained cycle.
            _ = try JobRepository.apply(db, .retryDeferred, to: F.identity(a), now: t0)
            run = try #require(try BackfillRunRepository.fetchAll(db).first)
            #expect(run.finishedAt == nil && run.waiting == 1 && run.retryable == 0)
            try BackfillRunRepository.finishSettled(db, now: t0)
            #expect(try Date.fetchOne(db, sql: "SELECT finished_at FROM backfill_run") == nil)
            try F.upload(db, F.identity(a), at: t0.addingTimeInterval(50))
            try BackfillRunRepository.finishSettled(db, now: t0.addingTimeInterval(60))
            #expect(try BackfillRunRepository.fetchAll(db).first?.finishedAt == t0.addingTimeInterval(50))

            // A destination removed in the middle of a run takes its jobs: the run finishes instead of running forever.
            let b = try F.file(db, "b")
            try BackfillRunRepository.close(db, trigger: .library, destinationId: nil, now: t0)
            try JobRepository.upsert(db, desired: desired(F.drive, b, origin: .backfill), now: t0)
            try db.execute(sql: "DELETE FROM upload_job WHERE asset_key = ?", arguments: [b.rawValue])
            try BackfillRunRepository.finishSettled(db, now: t0.addingTimeInterval(70))
            #expect(try BackfillRunRepository.fetchAll(db).allSatisfy { $0.finishedAt != nil })
        }
    }

    @Test func removingADestinationDropsItsIntegrityResultsButKeepsItsHistory() throws {
        let store = try Store.inMemory()
        try store.write { db in
            _ = try DestinationRepository.add(db, makeDestination(), now: t0)
            let a = try F.file(db, "a")
            try JobRepository.upsert(db, desired: desired(F.drive, a), now: t0)
            try F.upload(db, F.identity(a), at: t0)
            try IntegrityCheckRepository.record(db, identity: F.identity(a), result: .intact, at: t0)
            try DestinationRepository.remove(db, id: F.drive)
            #expect(try IntegrityCheckRepository.fetch(db, identity: F.identity(a)) == nil)
            #expect(try F.events(db).count == 1)
        }
    }
}
