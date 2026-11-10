import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultLocal
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// A Mac folder that calls `afterListing` once its listing is complete, just before handing it over.
private final class ListingHookSource: FolderImportSource, @unchecked Sendable {
    private let inner: LocalFolderSource
    private let afterListing: @Sendable () -> Void

    init(_ folder: ImportFolder, afterListing: @escaping @Sendable () -> Void) {
        inner = folder.source()
        self.afterListing = afterListing
    }

    var id: SourceID { inner.id }
    func probe() async throws { try await inner.probe() }
    func listFiles() async throws -> [FolderFileEntry] {
        let entries = try await inner.listFiles()
        afterListing()
        return entries
    }
    func inspect(relativePath: String, uti: String, mediaType: MediaType, control: ExportControl) async throws -> InspectedFile {
        try await inner.inspect(relativePath: relativePath, uti: uti, mediaType: mediaType, control: control)
    }
    func exportResource(_ locator: ResourceLocator, to destination: URL, control: ExportControl) async throws -> ExportedFile {
        try await inner.exportResource(locator, to: destination, control: control)
    }
}

/// Runs the jobs of the task that prefers it one at a time, and can run an action just before the next job starts.
/// A task suspended on a continuation is resumed by a new job, so the action lands after the result was handed over
/// and before the task looks at it. Work started with `Task {}` does not inherit the preference and runs elsewhere.
@available(macOS 15.0, *)
private final class SteppingExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ImportCancelChecksTests.stage")
    private let lock = NSLock()
    private var beforeNextJob: (@Sendable () -> Void)?

    func runBeforeNextJob(_ action: @escaping @Sendable () -> Void) { lock.withLock { beforeNextJob = action } }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { beforeNextJob = nil }
            return beforeNextJob
        }
        queue.async {
            action?()
            job.runSynchronously(on: self.asUnownedTaskExecutor())
        }
    }
}

/// The import stage checks for a cancel at four places besides the read and the listing it abandons. Each check only saves
/// work the cancel would undo, so these tests drive the stage's steps on their own, without the cancel's bookkeeping that
/// follows a pass, and look at what the step itself did.
@Suite struct ImportCancelChecksTests {
    /// A started import of `files` photos, one group each, and a stage over its environment. Transfers that start are
    /// counted; `onTransfersEmpty` runs each time the last running transfer ends (the read of the file in hand is over).
    private struct Setup {
        let h: Harness
        let folder: ImportFolder
        let id: SourceID
        let interrupts = ImportInterrupts()
        let transfersStarted = Box(0)
        let onTransfersEmpty = Box<(@Sendable () -> Void)?>(nil)
        let yieldAsked = Box(0)
        let onYieldAsked = Box<(@Sendable () -> Void)?>(nil)

        func stage() -> ImportStage {
            var env = h.env
            let started = transfersStarted
            let emptied = onTransfersEmpty
            let previous = Box(0)
            env.transfers = TransferTracker(clock: h.clock, minInterval: 0, onPublish: { items in
                let before = previous.get()
                previous.set(items.count)
                if items.count > before { started.mutate { $0 += items.count - before } }
                if items.isEmpty, before > 0 { emptied.get()?() }
            })
            let asked = yieldAsked
            let onAsked = onYieldAsked
            return ImportStage(env: env, extensions: [], interrupts: interrupts, commandWaiting: {
                asked.mutate { $0 += 1 }
                onAsked.get()?()
                return false
            })
        }

        var record: SourceRecord { get throws { try #require(try h.source(id)) } }
        var assets: Int { get throws { try h.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0 } } }
        var importItems: Int { get throws { try h.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM import_item") ?? 0 } } }
    }

    private func setUp(files: Int, source: ((ImportFolder) -> any FolderImportSource)? = nil) async throws -> Setup {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        let folder = try ImportFolder()
        for index in 0..<files {
            try folder.add("p\(index).jpg", metadata: ImportFolder.photo(at: h.clock.now.addingTimeInterval(-86_400 * Double(index + 2))))
        }
        let adapter = source?(folder) ?? folder.source()
        let id = try await h.coordinator.startFolderImport(source: adapter, displayName: "Trip", bookmark: nil)
        return Setup(h: h, folder: folder, id: id)
    }

    /// Lists the folder with no cancel, so the steps that read files can be driven next.
    private func listed(_ setup: Setup, _ stage: ImportStage) async throws -> SourceRecord {
        _ = try await stage.list(try setup.record, setup.folder.source())
        let record = try setup.record
        try #require(record.listedAt != nil)
        return record
    }

    @Test @available(macOS 15.0, *)
    func aListingThatArrivesAfterTheCancelRecordsNoFile() async throws {
        let executor = SteppingExecutor()
        let interrupts = Box<ImportInterrupts?>(nil)
        let job = Box<SourceID?>(nil)
        let setup = try await setUp(files: 3) { folder in
            ListingHookSource(folder) {
                // The listing is complete: the cancel lands once it has been handed over, before the stage looks at it.
                executor.runBeforeNextJob { if let id = job.get() { interrupts.get()?.requestCancel(id) } }
            }
        }
        interrupts.set(setup.interrupts)
        job.set(setup.id)
        let stage = setup.stage()
        let folder = try #require(await setup.h.env.sources.folder(for: setup.id))
        let source = try setup.record
        _ = try await withTaskExecutorPreference(executor) { try await stage.list(source, folder) }
        #expect(setup.interrupts.isCancelRequested(setup.id), "the cancel was asked while the listing was handed over")
        #expect(try setup.importItems == 0, "a listing that arrives after the cancel records no file")
        #expect(try setup.record.listedAt == nil)
    }

    @Test func aCancelWhileTheStageAsksAboutCommandsReadsNoFile() async throws {
        let setup = try await setUp(files: 1)
        let stage = setup.stage()
        let source = try await listed(setup, stage)
        let interrupts = setup.interrupts
        let id = setup.id
        // The cancel lands after the batch looked for one and before the group's first file is read.
        setup.onYieldAsked.set { interrupts.requestCancel(id) }
        _ = try await stage.ingestBatch(source, setup.folder.source())
        #expect(setup.yieldAsked.get() == 1)
        #expect(setup.transfersStarted.get() == 0, "no file is read once the cancel is asked")
        #expect(try setup.h.importCounts(id)[.pending] == 1)
    }

    @Test func aReadThatEndsAfterTheCancelIsNotRecorded() async throws {
        let setup = try await setUp(files: 1)
        let stage = setup.stage()
        let source = try await listed(setup, stage)
        let interrupts = setup.interrupts
        let id = setup.id
        // The read of the only file is complete and its result kept; the cancel lands before the group is recorded.
        setup.onTransfersEmpty.set { interrupts.requestCancel(id) }
        _ = try await stage.ingestBatch(source, setup.folder.source())
        #expect(setup.transfersStarted.get() == 1, "the file was read")
        #expect(try setup.assets == 0, "the group read before the cancel is not recorded")
        #expect(try setup.h.importCounts(id)[.pending] == 1)
        #expect(!setup.h.injector.visited.contains(.afterImportInspectBeforeCommit))
    }

    @Test func aCancelBetweenTwoGroupsEndsTheBatchBeforeTheNextGroup() async throws {
        let setup = try await setUp(files: 2)
        let stage = setup.stage()
        let source = try await listed(setup, stage)
        let interrupts = setup.interrupts
        let id = setup.id
        setup.h.injector.onReach { point in if point == .afterImportGroupCommit { interrupts.requestCancel(id) } }
        _ = try await stage.ingestBatch(source, setup.folder.source())
        #expect(try setup.assets == 1, "the first group was recorded before the cancel")
        #expect(setup.transfersStarted.get() == 1)
        #expect(setup.yieldAsked.get() == 1, "the batch ends at the cancel, before it considers the next group at all")
        #expect(try setup.h.importCounts(id)[.pending] == 1)
    }

    @Test func aListingAskedForByACancelledTaskEndsAtOnce() async throws {
        let setup = try await setUp(files: 1)
        let stage = setup.stage()
        let source = try setup.record
        let folder = setup.folder.source()
        let returned = Box(false)
        let listing = Task {
            defer { returned.set(true) }
            // The caller is cancelled before the stage starts to wait for the listing: the wait is over before it begins.
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await stage.list(source, folder)
        }
        let ended = await pollUntil { returned.get() }
        #expect(ended, "the stage does not hang on a wait that ended before it began")
        guard ended else { return }
        await #expect(throws: CancellationError.self) { try await listing.value }
        #expect(try setup.importItems == 0)
    }
}
