import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// A destination that throttles the burst of moves queued by a split day: the moves wait, they do
/// not burn their attempts, and a move that did fail is tried again.
@Suite struct SplitDayMoveThrottleTests {
    private let day = organizationDay

    /// Photos upload into the bare day folder; turning names on queues the split moves.
    private func prepare(hanoiCount: Int = 6, daLatCount: Int = 4) async throws -> Harness {
        let h = try await Harness.organized { $0.maxConcurrentUploadsPerDestination = 1 }
        try await h.update {
            $0.viewByDeviceEnabled = false
            $0.viewByPlaceEnabled = false
            $0.viewFavoritesEnabled = false
            $0.placeNamesEnabled = false
        }
        try h.addDrive(scope: .full)
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        await h.geocoder.seed(hanoi, en: hanoiEnglish, local: hanoiVietnamese)
        for index in 0..<hanoiCount { await h.add(h.snapshot("h\(index)", daysAgo: 3, location: hanoi), recordChange: false) }
        for index in 0..<daLatCount { await h.add(h.snapshot("d\(index)", daysAgo: 3, location: daLat), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.settle()
        try await h.update { $0.placeNamesEnabled = true }
        return h
    }

    private func moveCalls(_ h: Harness) async -> Int { await h.drive.operationLog.filter { $0 == .move }.count }

    private func expectSplit(_ h: Harness, daLatCount: Int = 4) async throws {
        let paths = await h.backupPaths(h.drive)
        #expect(paths.filter { $0.hasPrefix("Camera Uploads/\(day) Đà Lạt/") }.count == daLatCount, "\(paths)")
        for state in [MoveJobState.pending, .inProgress, .failed] { #expect(try h.moveJobs(state, destination: .googleDrive).isEmpty, "\(state)") }
    }

    /// Queues the split's moves; one throttled call leaves them all pending.
    private func prepareQueued() async throws -> Harness {
        let h = try await prepare()
        await h.drive.failNext(.move, with: .rateLimited(retryAfter: nil))
        await h.run()
        #expect(try h.moveJobs(.pending, destination: .googleDrive).count > 4)
        return h
    }

    @Test(arguments: [DestinationError.rateLimited(retryAfter: nil), .server(status: 503), .transient(reason: "reset")])
    func aThrottledBurstOfMovesNeverFailsAndFinishesWhenTheThrottleLifts(_ error: DestinationError) async throws {
        let h = try await prepare()
        await h.drive.failNext(.move, with: error, times: 60)
        for _ in 0..<80 {
            await h.run()
            #expect(try h.moveJobs(.failed, destination: .googleDrive).isEmpty)
            #expect(try h.read { db in try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(attempts), 0) FROM move_job") } == 0, "throttling never costs an attempt")
            h.clock.advance(by: 3600)
        }
        try await expectSplit(h)
    }

    @Test func aThrottledMoveStopsTheDestinationsPassAndBacksItOff() async throws {
        let h = try await prepare()
        await h.drive.failNext(.move, with: .rateLimited(retryAfter: nil), times: 1000)
        await h.run()
        #expect(await moveCalls(h) == 1, "the pass stops at the first throttled call")
        #expect(try h.moveJobs(.pending, destination: .googleDrive).count > 1)
        // Hours later the backoff is over and the destination is tried again, once.
        h.clock.advance(by: 3600)
        await h.run()
        #expect(await moveCalls(h) == 2)
    }

    @Test func uploadsAndMovesOfTheSameDestinationBothFinishOnceTheThrottleLifts() async throws {
        let h = try await prepare()
        await h.drive.failNext(.move, with: .rateLimited(retryAfter: nil), times: 5)
        await h.add(h.snapshot("late", daysAgo: 3, location: hanoi))
        for _ in 0..<12 {
            await h.run()
            h.clock.advance(by: 3600)
        }
        #expect(await h.backupPaths(h.drive).contains { $0.contains("late") })
        try await expectSplit(h)
    }

    @Test func aFailedMoveIsTriedAgainOnTheNextLaunchAndFinishes() async throws {
        let h = try await prepareQueued()
        try h.write { db in try db.execute(sql: "UPDATE move_job SET state = 'failed', attempts = 9, last_error = 'x' WHERE state = 'pending'") }
        #expect(try h.moveJobs(.failed, destination: .googleDrive).count > 4)
        try await h.restart()
        try await h.coordinator.start()
        await h.settle(rounds: 8)
        try await expectSplit(h)
    }

    @Test func movesThatFailedBeforeDoNotBlockTheOnesBehindThem() async throws {
        let h = try await prepareQueued()
        let first = try #require(try h.read { db in
            try Int64.fetchOne(db, sql: "SELECT MIN(id) FROM move_job WHERE op = 'moveFile' AND state = 'pending'")
        })
        try h.write { db in try db.execute(sql: "UPDATE move_job SET attempts = 5 WHERE id = ?", arguments: [first]) }
        let order = try h.read { db in try MoveJobRepository.fetch(db, destinationId: .googleDrive, state: .pending) }
        #expect(order.first(where: { $0.operation == .moveFile })?.id != first)
        #expect(order.last(where: { $0.operation == .moveFile })?.id == first)
    }

    @Test func aFailedFolderRenameIsNotQueuedAgainAtLaunch() async throws {
        let h = try await prepare()
        await h.settle(rounds: 8)
        let main = "camera/\(day)"
        let name = try #require(try h.read { db in
            try String.fetchOne(db, sql: "SELECT display_name FROM remote_folder WHERE destination_id = 'gdrive' AND logical_path = ?", arguments: [main])
        })
        // A rename to "Bravo" ended failed; the day's name has since become "Charlie", queued from the name on disk.
        try h.write { db in
            let now = h.clock.now
            try MoveJobRepository.insert(db, MoveJob(
                destinationId: .googleDrive, operation: .renameFolder, subject: main, fromValue: name, toValue: "Bravo", state: .failed, attempts: 9, createdAt: now))
            try MoveJobRepository.insert(db, MoveJob(
                destinationId: .googleDrive, operation: .renameFolder, subject: main, fromValue: name, toValue: "Charlie", createdAt: now))
        }
        try await h.restart()
        try await h.coordinator.start()
        await h.settle(rounds: 4)
        let folders = await h.drive.folders.map(\.name)
        #expect(folders.contains("Charlie") && !folders.contains("Bravo"), "\(folders)")
        #expect(try h.moveJobs(.failed, destination: .googleDrive).count == 1, "the failed rename stays as it was")
    }

    @Test func aMoveThatSucceedsEndsTheDestinationsRunOfFailures() async throws {
        let h = try await prepareQueued()
        let uploader = UploadRunner(env: h.env, staging: StagingManager(env: h.env))
        let worker = MoveWorker(env: h.env, uploader: uploader)
        await h.drive.failNext(.move, with: .rateLimited(retryAfter: nil), times: 3)
        for _ in 0..<10 {
            _ = try await worker.runPass()
            h.clock.advance(by: 3600)
        }
        #expect(try h.moveJobs(.pending, destination: .googleDrive).isEmpty)
        #expect(await uploader.consecutive(.googleDrive) == 0, "the next throttle starts its backoff from the beginning")
        #expect(await !uploader.isBackedOff(.googleDrive))
    }
}
