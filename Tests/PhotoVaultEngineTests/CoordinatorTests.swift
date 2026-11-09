import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

private final class CountingStage: CycleStage, @unchecked Sendable {
    let step: CycleStep
    private let lock = NSLock()
    private var calls = 0
    private let onFirst: (@Sendable () async -> Void)?
    init(_ step: CycleStep, onFirst: (@Sendable () async -> Void)? = nil) {
        self.step = step
        self.onFirst = onFirst
    }
    var count: Int { lock.withLock { calls } }
    func run(trigger: SyncTrigger) async throws -> Bool {
        let first = lock.withLock { () -> Bool in
            calls += 1
            return calls == 1
        }
        if first { await onFirst?() }
        return false
    }
}

private struct RecordingReconciler: ReconciliationRunning {
    let box: ReasonBox
    func reconcile(reason: ReconciliationReason) async throws { box.record(reason) }
}

private final class ReasonBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reasons: [ReconciliationReason] = []
    func record(_ r: ReconciliationReason) { lock.withLock { reasons.append(r) } }
    var all: [ReconciliationReason] { lock.withLock { reasons } }
}

@Suite struct CoordinatorTests {
    @Test func triggersDuringARunScheduleExactlyOneFollowUp() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        final class Box: @unchecked Sendable { var coordinator: SyncCoordinator? }
        let box = Box()
        let relay = CountingStage(.cloudIds) {
            for trigger in [SyncTrigger.photosChanged, .networkBack, .timer] { _ = await box.coordinator?.run(trigger: trigger) }
        }
        let coordinator = SyncCoordinator(env: h.env, stages: [relay])
        box.coordinator = coordinator
        let outcome = await coordinator.run(trigger: .launch)
        guard case .completed = outcome else {
            Issue.record("expected a completed cycle, got \(outcome)")
            return
        }
        #expect(relay.count == 2, "one original cycle plus exactly one follow-up")
        _ = await coordinator.run(trigger: .manual)
        #expect(relay.count == 3)
    }

    @Test func stagesRunAtTheirStepsAndMakeTheCycleRepeatOnProgress() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        final class Worker: CycleStage, @unchecked Sendable {
            let step = CycleStep.moves
            private let lock = NSLock()
            private var left = 2
            var runs = 0
            func run(trigger: SyncTrigger) async throws -> Bool {
                lock.withLock {
                    runs += 1
                    defer { left -= 1 }
                    return left > 0
                }
            }
        }
        let worker = Worker()
        let coordinator = SyncCoordinator(env: h.env, stages: [worker])
        let outcome = await coordinator.run(trigger: .manual)
        guard case .completed(let report) = outcome else {
            Issue.record("incomplete")
            return
        }
        #expect(worker.runs == 3 && report.stageWork == 2 && report.rounds == 3)
    }

    @Test func reconciliationHookRunsWhenTheTokenExpired() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("a"), recordChange: false)
        try await h.baseline(.googleDrive)
        _ = try await h.coordinator.scanner.run()
        await h.add(h.snapshot("b"))
        await h.fakePhotos.expireHistory()
        let box = ReasonBox()
        let coordinator = SyncCoordinator(env: h.env, reconciler: RecordingReconciler(box: box))
        _ = await coordinator.run(trigger: .manual)
        #expect(box.all == [.tokenExpired])
    }

    @Test func pauseAllAndPerDestinationPause() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try h.addNAS(scope: .full)
        await h.add(h.snapshot("p"), recordChange: false)
        try await h.baseline(.googleDrive, h.nasId)

        await h.coordinator.pauseAll()
        #expect(await h.run() == .paused)
        #expect(await h.coordinator.currentSnapshot().overall == .paused)
        await h.coordinator.resumeAll()

        try await h.coordinator.pause(destination: h.nasId)
        await h.run()
        #expect(await h.drive.files.count == 1)
        #expect(await h.nas.files.isEmpty)
        let paused = try h.read { db in try DestinationRepository.fetch(db, id: h.nasId)?.status }
        #expect(paused == .paused(.userPaused))
        await h.run()
        #expect(await h.nas.files.isEmpty, "availability checks do not undo an owner pause")

        try await h.coordinator.resume(destination: h.nasId)
        await h.run()
        #expect(await h.nas.files.count == 1)
    }

    @Test func blockedWithoutPhotosPermissionOrBaseline() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        #expect(await h.run() == .blocked(.notBaselined))
        try await h.baseline(.googleDrive)
        h.photos.authorization = .denied
        #expect(await h.run() == .blocked(.photosUnauthorized))
        #expect(await h.coordinator.currentSnapshot().overall == .photosUnauthorized)
        h.photos.authorization = .authorized
        guard case .completed = await h.run() else {
            Issue.record("should run once authorized")
            return
        }
    }

    @Test func snapshotReportsCountsBackfillProgressBytesAndEta() async throws {
        let h = try await Harness()
        try await h.update { $0.backfillBytesPerHour = 20 << 20 }
        try h.addDrive(scope: .full)
        for i in 0..<6 { await h.add(h.snapshot("s\(i)", daysAgo: Double(i + 1)), recordChange: false) }
        try await h.baseline(.googleDrive)
        let stream = await h.coordinator.snapshots()
        await h.run()
        h.clock.advance(by: 1800)
        await h.run()
        let snapshot = await h.coordinator.currentSnapshot()
        #expect(snapshot.scanState == .complete)
        #expect(snapshot.backfillTotalAssets == 6)
        #expect(snapshot.backfillDoneAssets > 0 && snapshot.backfillDoneAssets < 6)
        #expect(snapshot.bytesUploaded > 0)
        #expect(snapshot.pending == 6 - snapshot.backfillDoneAssets)
        let drive = try #require(snapshot.destinations.first)
        #expect(drive.pending == snapshot.pending && drive.lastSuccessAt != nil && drive.status == .active)
        #expect(snapshot.etaSeconds.map { $0 > 0 } == true)
        var received: EngineSnapshot?
        for await item in stream {
            received = item
            break
        }
        #expect(received != nil)

        for _ in 0..<8 {
            h.clock.advance(by: 3600)
            await h.run()
        }
        let done = await h.coordinator.currentSnapshot()
        #expect(done.pending == 0 && done.backfillDoneAssets == 6 && done.overall == .idle)
    }

    @Test func offlineNetworkIsReportedAndUploadsWait() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("n"), recordChange: false)
        try await h.baseline(.googleDrive)
        h.system.set(SystemSnapshot(networkAvailable: false))
        await h.run()
        #expect(await h.coordinator.currentSnapshot().overall == .offline)
        #expect(await h.drive.files.isEmpty)
        h.system.set(SystemSnapshot())
        await h.run(.networkBack)
        #expect(await h.drive.files.count == 1)
    }

    @Test func logsCarryJobIdsButNeverFileNamesOrCoordinates() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("secretname", location: GeoPoint(latitude: 11.9404, longitude: 108.4583)), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.run()
        #expect(h.log.contains("job="))
        #expect(!h.log.contains("secretname"))
        #expect(!h.log.contains("11.94"))
        #expect(!h.log.contains("session-"))
    }
}
