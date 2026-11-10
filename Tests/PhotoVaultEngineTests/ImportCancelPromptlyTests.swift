import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultLocal
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// A folder whose reads take time, as a synced online-only file or a slow download does. While `hold` is set a read
/// waits for `release()`; it gives up with `cancelled` when the engine cancels its control, as a real adapter does.
private final class SlowReadSource: FolderImportSource, @unchecked Sendable {
    private let inner: LocalFolderSource
    private let lock = NSLock()
    private var entered = 0
    private var released = false
    private var exported = 0
    private var listEntered = 0
    private var readsEnded = 0
    private var listingsEnded = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let hold: Bool
    private let delay: Duration
    /// The read waits for `release()` and looks neither at its control nor at task cancellation, as an adapter that
    /// cannot be interrupted.
    private let ignoresCancel: Bool
    /// The listing waits for `release()` and ignores cancellation.
    private let holdsListing: Bool

    init(_ folder: ImportFolder, hold: Bool, delay: Duration = .milliseconds(0), ignoresCancel: Bool = false, holdsListing: Bool = false) {
        inner = folder.source()
        self.hold = hold
        self.delay = delay
        self.ignoresCancel = ignoresCancel
        self.holdsListing = holdsListing
    }

    var exports: Int { lock.withLock { exported } }
    var listings: Int { lock.withLock { listEntered } }

    var id: SourceID { inner.id }
    var reads: Int { lock.withLock { entered } }
    /// Reads and listings that have run to their end, whatever their outcome.
    var finishedReads: Int { lock.withLock { readsEnded } }
    var finishedListings: Int { lock.withLock { listingsEnded } }
    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            defer { waiters = [] }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }

    /// Waits for `release()` and does not see task cancellation, as a call that cannot be interrupted.
    private func waitForRelease() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if released { return true }
                waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func probe() async throws { try await inner.probe() }
    func listFiles() async throws -> [FolderFileEntry] {
        lock.withLock { listEntered += 1 }
        defer { lock.withLock { listingsEnded += 1 } }
        if holdsListing { await waitForRelease() }
        return try await inner.listFiles()
    }
    func inspect(relativePath: String, uti: String, mediaType: MediaType, control: ExportControl) async throws -> InspectedFile {
        lock.withLock { entered += 1 }
        defer { lock.withLock { readsEnded += 1 } }
        if hold, ignoresCancel { await waitForRelease() }
        while hold, !ignoresCancel, !lock.withLock({ released }) {
            if control.isCancelled { throw SourceError.cancelled }
            try await Task.sleep(for: .milliseconds(10))
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        return try await inner.inspect(relativePath: relativePath, uti: uti, mediaType: mediaType, control: control)
    }
    func exportResource(_ locator: ResourceLocator, to destination: URL, control: ExportControl) async throws -> ExportedFile {
        lock.withLock { exported += 1 }
        return try await inner.exportResource(locator, to: destination, control: control)
    }
}

private actor Gate {
    private var held = false
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var isHeld: Bool { held }
    func hold() async {
        held = true
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { opened = true; waiters.forEach { $0.resume() }; waiters = [] }
}

@Suite struct ImportCancelPromptlyTests {
    private func harness(files: Int, tuning: ((inout EngineTuning) -> Void)? = nil) async throws -> (Harness, ImportFolder) {
        let h = try await Harness(tuning: tuning)
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        let folder = try ImportFolder()
        for index in 0..<files {
            try folder.add("p\(index).jpg", metadata: ImportFolder.photo(at: h.clock.now.addingTimeInterval(-86_400 * Double(index + 2))))
        }
        return (h, folder)
    }

    @Test func cancelStopsAReadThatIsInProgressWithinSeconds() async throws {
        let (h, folder) = try await harness(files: 3)
        let source = SlowReadSource(folder, hold: true)
        let id = try await h.coordinator.startFolderImport(source: source, displayName: "Trip", bookmark: nil)
        let cycle = Task { await h.coordinator.run(trigger: .manual) }
        #expect(await eventually { source.reads >= 1 })
        let cancel = Task { try await h.coordinator.cancelImport(id) }
        let cancelled = try await eventually { try h.source(id)?.status == .cancelled }
        source.release()
        _ = await cycle.value
        try await cancel.value
        #expect(cancelled, "the read in progress is cancelled and the import ends while the cycle is still inside it")
        #expect(source.reads == 1, "no other file is read after the cancel")
    }

    @Test func theCancelIsStoredBeforeTheLaneIsGranted() async throws {
        let (h, folder) = try await harness(files: 1)
        let source = SlowReadSource(folder, hold: false)
        let id = try await h.coordinator.startFolderImport(source: source, displayName: "Trip", bookmark: nil)
        let coordinator = h.coordinator
        let gate = Gate()
        let holder = Task { await coordinator.exclusive { await gate.hold() } }
        #expect(await eventually { await gate.isHeld })
        let cancel = Task { try await coordinator.cancelImport(id) }
        let stored = try await eventually { try h.source(id)?.config.cancelRequested == true }
        let stillOpen = try h.source(id)?.status.isOpen == true
        await gate.open()
        await holder.value
        try await cancel.value
        #expect(stored, "the intent is in the database while the lane is still held")
        #expect(stillOpen, "the bookkeeping waits for the lane")
        #expect(try h.source(id)?.status == .cancelled)
    }

    @Test func aStoredCancelIsHonouredByTheNextCycle() async throws {
        let (h, folder) = try await harness(files: 2)
        let source = SlowReadSource(folder, hold: false)
        let id = try await h.coordinator.startFolderImport(source: source, displayName: "Trip", bookmark: nil)
        try await h.store.write { db in try SourceRepository.requestCancel(db, id: id) }
        _ = await h.coordinator.run(trigger: .manual)
        #expect(try h.source(id)?.status == .cancelled)
        #expect(source.reads == 0)
    }

    @Test func aWaitingCommandStopsTheImportBatchAfterTheGroupInHand() async throws {
        let (h, folder) = try await harness(files: 20)
        let source = SlowReadSource(folder, hold: false, delay: .milliseconds(30))
        _ = try await h.coordinator.startFolderImport(source: source, displayName: "Trip", bookmark: nil)
        let coordinator = h.coordinator
        let cycle = Task { await coordinator.run(trigger: .manual) }
        #expect(await eventually { source.reads >= 2 })
        let readsWhenTheCommandRan = Task { await coordinator.exclusive { source.reads } }
        let seen = await readsWhenTheCommandRan.value
        _ = await cycle.value
        #expect(seen < 10, "the command waited for \(seen) of 20 reads")
    }

    @Test func pauseStopsTheImportBatchAfterTheGroupInHand() async throws {
        let (h, folder) = try await harness(files: 20)
        let source = SlowReadSource(folder, hold: false, delay: .milliseconds(30))
        _ = try await h.coordinator.startFolderImport(source: source, displayName: "Trip", bookmark: nil)
        let coordinator = h.coordinator
        let cycle = Task { await coordinator.run(trigger: .manual) }
        #expect(await eventually { source.reads >= 2 })
        await coordinator.pauseAll()
        let outcome = await cycle.value
        #expect(source.reads < 10, "pause let \(source.reads) of 20 reads run")
        #expect(outcome == .paused)
    }

    @Test func aCancelMidBatchExportsNothingFromTheGroupsAlreadyRead() async throws {
        let (h, folder) = try await harness(files: 20)
        let source = SlowReadSource(folder, hold: false, delay: .milliseconds(30))
        let id = try await h.coordinator.startFolderImport(source: source, displayName: "Trip", bookmark: nil)
        let coordinator = h.coordinator
        let cycle = Task { await coordinator.run(trigger: .manual) }
        #expect(await eventually { source.reads >= 6 })
        try await coordinator.cancelImport(id)
        _ = await cycle.value
        #expect(try h.source(id)?.status == .cancelled)
        #expect(source.exports == 0, "the exporter must not read the cancelled import's files again")
        #expect(source.reads < 20)
    }

    @Test func aReadThatCannotBeInterruptedIsAbandonedAndItsResultDropped() async throws {
        let (h, folder) = try await harness(files: 1)
        let source = SlowReadSource(folder, hold: true, ignoresCancel: true)
        let id = try await h.coordinator.startFolderImport(source: source, displayName: "Trip", bookmark: nil)
        let coordinator = h.coordinator
        let cycle = Task { await coordinator.run(trigger: .manual) }
        #expect(await eventually { source.reads >= 1 })
        let cancel = Task { try await coordinator.cancelImport(id) }
        let cancelled = try await eventually(10) { try h.source(id)?.status == .cancelled }
        source.release()
        _ = await cycle.value
        try await cancel.value
        #expect(cancelled, "the cancel does not wait for the read")
        #expect(await eventually(10) { source.finishedReads == 1 }, "the abandoned read runs to its end in the background")
        #expect(source.exports == 0)
        #expect(try h.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") } == 0, "the dropped read is not committed")
    }

    @Test func aCancelBetweenTwoGroupsStartsNoFurtherRead() async throws {
        let (h, folder) = try await harness(files: 20)
        let source = SlowReadSource(folder, hold: false)
        let id = try await h.coordinator.startFolderImport(source: source, displayName: "Trip", bookmark: nil)
        let interrupts = h.coordinator.importInterrupts
        // The cancel lands right after the first group is committed, while no read is in flight and no command waits.
        h.injector.onReach { point in if point == .afterImportGroupCommit { interrupts.requestCancel(id) } }
        _ = await h.coordinator.run(trigger: .manual)
        #expect(source.reads == 1, "\(source.reads) reads were started after the cancel")
        #expect(try h.source(id)?.status == .cancelled, "the cycle finishes the cancel itself")
        #expect(source.exports == 0)
    }

    @Test func aCancelDoesNotWaitForAListingThatCannotBeInterrupted() async throws {
        let (h, folder) = try await harness(files: 3)
        let source = SlowReadSource(folder, hold: false, holdsListing: true)
        let id = try await h.coordinator.startFolderImport(source: source, displayName: "Trip", bookmark: nil)
        let coordinator = h.coordinator
        let cycle = Task { await coordinator.run(trigger: .manual) }
        #expect(await eventually { source.listings >= 1 })
        let cancel = Task { try await coordinator.cancelImport(id) }
        let cancelled = try await eventually(10) { try h.source(id)?.status == .cancelled }
        source.release()
        _ = await cycle.value
        try await cancel.value
        #expect(cancelled, "the cancel does not wait for the listing")
        #expect(await eventually(10) { source.finishedListings == 1 }, "the abandoned listing runs to its end in the background")
        #expect(try h.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM import_item") } == 0, "nothing is written after the listing ends")
    }

    @Test func theSnapshotShowsAStoredCancel() async throws {
        let (h, folder) = try await harness(files: 1)
        let id = try await h.coordinator.startFolderImport(source: SlowReadSource(folder, hold: false), displayName: "Trip", bookmark: nil)
        #expect(await h.coordinator.currentSnapshot().imports.first?.cancelRequested == false)
        try await h.store.write { db in try SourceRepository.requestCancel(db, id: id) }
        await h.coordinator.publish()
        #expect(await h.coordinator.currentSnapshot().imports.first?.cancelRequested == true)
    }

    @Test func startingTheEngineFinishesAStoredCancel() async throws {
        let (h, folder) = try await harness(files: 2)
        let source = SlowReadSource(folder, hold: false)
        let id = try await h.coordinator.startFolderImport(source: source, displayName: "Trip", bookmark: nil)
        try await h.store.write { db in try SourceRepository.requestCancel(db, id: id) }
        _ = try await h.coordinator.start()
        #expect(try h.source(id)?.status == .cancelled, "no cycle is needed")
        #expect(source.reads == 0)
    }

    @Test func aFailedIntentWriteLeavesTheImportRunning() async throws {
        let (h, folder) = try await harness(files: 1)
        let id = try await h.coordinator.startFolderImport(source: SlowReadSource(folder, hold: false), displayName: "Trip", bookmark: nil)
        try await h.store.write { db in try db.execute(sql: "DROP TABLE source") }
        await #expect(throws: (any Error).self) { try await h.coordinator.cancelImport(id) }
        #expect(!h.coordinator.importInterrupts.isCancelRequested(id), "no in-memory cancel when the intent was not stored")
    }

    @Test func reconnectingKeepsAStoredCancel() async throws {
        let (h, folder) = try await harness(files: 1)
        let id = try await h.coordinator.startFolderImport(source: SlowReadSource(folder, hold: false), displayName: "Trip", bookmark: nil)
        try await h.store.write { db in try SourceRepository.requestCancel(db, id: id) }
        try await h.store.write { db in try SourceRepository.updateConfig(db, id: id) { $0.account = "me@example.com" } }
        let config = try #require(try h.source(id)?.config)
        #expect(config.account == "me@example.com" && config.cancelRequested == true)
    }
}
