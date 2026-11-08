import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// Owner commands and the cycle never interleave (NFR-01), and a cycle that lasts hours still
/// follows pause, network, destination status and Photos changes.
@Suite struct ExclusiveLaneTests {
    private func harness(photos: Int = 6) async throws -> (Harness, WrappedDestination) {
        let h = try await Harness { $0.maxConcurrentUploadsPerDestination = 1 }
        let wrapper = WrappedDestination(h.drive)
        await h.useWrapped(wrapper)
        h.overrides = [wrapper]
        try h.addDrive(scope: .full)
        for index in 0..<photos { await h.add(h.snapshot("p\(index)", daysAgo: Double(index + 1)), recordChange: false) }
        try await h.baseline(.googleDrive)
        return (h, wrapper)
    }

    /// Yields until `condition` holds (bounded, so a bug fails the test instead of hanging it).
    private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }

    @Test func aCommandIssuedDuringALongCycleRunsBetweenJobsAndNeverSeesAHalfFinishedUpload() async throws {
        let (h, wrapper) = try await harness()
        let coordinator = h.coordinator
        let fired = Flag()
        let seenAtList = Box<[(running: Int, uploaded: Int)]>([])
        wrapper.onList = { running in
            guard fired.isSet else { return }
            seenAtList.mutate { $0.append((running, wrapper.uploadedNames.count)) }
        }
        let check = Box<Task<IntegrityReport, any Error>?>(nil)
        wrapper.beforeUpload = { _ in
            guard fired.takeFirst() else { return }
            check.set(Task { try await coordinator.runIntegrityCheck(.googleDrive) })
            // The owner's request is queued while this upload is still in flight.
            _ = await self.eventually { await coordinator.lane.hasWaitingCommands }
        }
        await h.run()

        let report = try #require(try await check.get()?.value)
        #expect(report.missing == 0, "a file that finished during the check is not reported missing")
        #expect(try h.jobs(.missingRemote).isEmpty)
        let seen = try #require(seenAtList.get().first)
        #expect(seen.running == 0, "the check ran while no upload was in flight")
        #expect(seen.uploaded == 1 && seen.uploaded < 6, "it ran at a pass boundary, before the backlog was done")
        #expect(await h.drive.files.count == 6, "the cycle resumed and finished the backlog")
        #expect(try h.jobs(.done).count == 6)
    }

    @Test func pausingAllDuringTheCycleStopsNewUploadsAtOnce() async throws {
        let (h, wrapper) = try await harness()
        let coordinator = h.coordinator
        let fired = Flag()
        wrapper.beforeUpload = { _ in if fired.takeFirst() { await coordinator.pauseAll() } }
        await h.run()
        #expect(await h.drive.files.count == 1, "only the upload that was already running finished")
        await coordinator.resumeAll()
        await h.run()
        #expect(await h.drive.files.count == 6)
    }

    @Test func anExpensiveNetworkDuringTheCycleHoldsTheRestOfTheBacklog() async throws {
        let (h, wrapper) = try await harness()
        let fired = Flag()
        let system = h.system
        wrapper.beforeUpload = { _ in if fired.takeFirst() { system.set(SystemSnapshot(networkExpensive: true)) } }
        await h.run()
        #expect(await h.drive.files.count == 1)
        system.set(SystemSnapshot())
        await h.run()
        #expect(await h.drive.files.count == 6)
    }

    @Test func aDestinationPausedDuringTheCycleStopsGettingJobs() async throws {
        let (h, wrapper) = try await harness()
        let coordinator = h.coordinator
        let fired = Flag()
        wrapper.beforeUpload = { _ in if fired.takeFirst() { try? await coordinator.pause(destination: .googleDrive) } }
        await h.run()
        #expect(await h.drive.files.count == 1)
    }

    @Test func aNewPhotoIsUploadedBeforeTheRestOfTheBacklog() async throws {
        let (h, wrapper) = try await harness()
        let coordinator = h.coordinator
        let fired = Flag()
        let photos = h.fakePhotos
        let fresh = h.snapshot("fresh", daysAgo: 0.1)
        wrapper.beforeUpload = { _ in
            guard fired.takeFirst() else { return }
            await photos.add(fresh, header: camera, recordChange: true)
            _ = await coordinator.run(trigger: .photosChanged)
        }
        await h.run()
        let names = wrapper.uploadedNames
        #expect(names.count == 7)
        let position = try #require(names.firstIndex { $0.contains("fresh") })
        #expect(position <= 2, "picked up at the next pass boundary, not after the backlog: \(names)")
    }

    @Test func removingADestinationStopsOnlyItsTransfers() async throws {
        let h = try await Harness { $0.maxConcurrentUploadsPerDestination = 1 }
        let wrapper = WrappedDestination(h.drive)
        await h.useWrapped(wrapper)
        h.overrides = [wrapper]
        try h.addDrive(scope: .full)
        try h.addNAS(scope: .full)
        for index in 0..<3 { await h.add(h.snapshot("p\(index)", daysAgo: Double(index + 1)), recordChange: false) }
        try await h.baseline(.googleDrive, h.nasId)
        let entered = Flag()
        wrapper.beforeUpload = { _ in
            // Only the first transfer hangs; cancelling it ends the sleep at once.
            guard entered.takeFirst() else { return }
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
        let coordinator = h.coordinator
        let cycle = Task { await h.run() }
        #expect(await eventually { entered.isSet })
        await coordinator.destinationRemoved(.googleDrive)
        let outcome = await cycle.value
        guard case .completed = outcome else {
            Issue.record("the cycle must complete, got \(outcome)")
            return
        }
        #expect(await h.nas.files.count == 3, "the other destination was not interrupted")
        #expect(await h.drive.files.isEmpty)
    }

    @Test func aJobRemovedWhileItsUploadRunsDoesNotFailTheCycle() async throws {
        let (h, wrapper) = try await harness(photos: 2)
        let fired = Flag()
        let store = h.store
        wrapper.beforeUpload = { _ in
            if fired.takeFirst() { try store.write { db in try db.execute(sql: "DELETE FROM upload_job") } }
        }
        let outcome = await h.run()
        guard case .completed = outcome else {
            Issue.record("a vanished job must not fail the cycle, got \(outcome)")
            return
        }
    }

    @Test func changingTheDriveRootStopsOnlyThatDestinationsTransfers() async throws {
        let h = try await Harness { $0.maxConcurrentUploadsPerDestination = 1 }
        let wrapper = ControllableDrive(h.drive)
        await h.env.destinations.add(wrapper)
        h.overrides = [wrapper]
        try h.addDrive(scope: .full)
        try h.addNAS(scope: .full)
        for index in 0..<3 { await h.add(h.snapshot("p\(index)", daysAgo: Double(index + 1)), recordChange: false) }
        try await h.baseline(.googleDrive, h.nasId)
        let entered = Flag()
        wrapper.beforeUpload = {
            guard entered.takeFirst() else { return }
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
        let coordinator = h.coordinator
        let cycle = Task { await h.run() }
        #expect(await eventually { entered.isSet })
        try await coordinator.changeDriveRoot(.googleDrive, rootId: "root", rootName: "Camera Uploads", rootHasContent: false)
        let outcome = await cycle.value
        guard case .completed = outcome else {
            Issue.record("the cycle must complete, got \(outcome)")
            return
        }
        #expect(await h.nas.files.count == 3, "the other destination was not interrupted")
        #expect(try h.jobs(.done, destination: h.nasId).count == 3)
    }

    @Test func commandsRunOneAfterTheOtherWhenNoCycleIsRunning() async throws {
        let (h, wrapper) = try await harness(photos: 2)
        await h.run()
        let events = Box<[String]>([])
        wrapper.listEvents = events
        wrapper.listDuration = 20_000_000
        let coordinator = h.coordinator
        async let first = coordinator.runIntegrityCheck(.googleDrive)
        async let second = coordinator.runIntegrityCheck(.googleDrive)
        async let third = coordinator.runIntegrityCheck(nil)
        let reports = try await [first, second, third]
        #expect(reports.allSatisfy { $0.missing == 0 })
        #expect(events.get() == ["enter", "exit", "enter", "exit", "enter", "exit"], "no command started before the previous one ended: \(events.get())")
    }

    @Test func aCommandIsServedBetweenScanBatchesNotAfterTheWholeScan() async throws {
        let h = try await Harness { $0.maxConcurrentUploadsPerDestination = 1; $0.scanBatchSize = 2 }
        let wrapper = WrappedDestination(h.drive)
        await h.useWrapped(wrapper)
        h.overrides = [wrapper]
        try h.addDrive(scope: .full)
        for index in 0..<6 { await h.add(h.snapshot("p\(index)", daysAgo: Double(index + 1)), recordChange: false) }
        try await h.baseline(.googleDrive)
        let coordinator = h.coordinator
        let store = h.store
        let scannedAtCheck = Box<Int?>(nil)
        wrapper.onList = { _ in
            scannedAtCheck.set((try? store.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") }) ?? nil)
        }
        let fired = Flag()
        let check = Box<Task<IntegrityReport, any Error>?>(nil)
        h.photos.onFetch = {
            guard fired.takeFirst() else { return }
            check.set(Task { try await coordinator.runIntegrityCheck(.googleDrive) })
            _ = await self.eventually { await coordinator.lane.hasWaitingCommands }
        }
        await h.run()
        _ = try await check.get()?.value
        let scanned = try #require(scannedAtCheck.get())
        #expect(scanned < 6, "the check ran while the scan was still going, not after all 6 assets were read: \(scanned)")
        #expect(try h.jobs(.done).count == 6, "the scan and the uploads carried on afterwards")
    }

    @Test func aCommandThatStopsTheUploadGateGetsExactlyOneFollowUpRun() async throws {
        let (h, wrapper) = try await harness()
        let coordinator = h.coordinator
        // Everything is exported and queued first, so the run below has nothing but uploads to do.
        h.system.set(SystemSnapshot(networkExpensive: true))
        await h.run()
        h.system.set(SystemSnapshot())
        #expect(await h.drive.files.isEmpty)
        let fired = Flag()
        let check = Box<Task<IntegrityReport, any Error>?>(nil)
        let checksBefore = wrapper.availabilityChecks
        wrapper.beforeUpload = { _ in
            guard fired.takeFirst() else { return }
            check.set(Task { try await coordinator.runIntegrityCheck(.googleDrive) })
            _ = await self.eventually { await coordinator.lane.hasWaitingCommands }
            // The one upload in flight fails, so the round ends without progress.
            throw DestinationError.itemRejected(reason: "rejected")
        }
        let outcome = await h.run()
        guard case .completed = outcome else {
            Issue.record("expected a completed cycle, got \(outcome)")
            return
        }
        let report = try #require(try await check.get()?.value)
        #expect(report.skippedDestinations.isEmpty)
        let cycles = wrapper.availabilityChecks - checksBefore
        #expect(cycles == 2, "the run and exactly one follow-up run, not one per refused upload: \(cycles)")
        #expect(await h.drive.files.count == 5, "the backlog went on after the command without waiting for the next trigger")
    }
}

/// Small lock-protected cell for values a test hook sets.
final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ new: Value) { lock.withLock { value = new } }
    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&value) } }
}
