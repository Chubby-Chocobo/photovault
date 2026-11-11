import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultLocal
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// Waits in these tests only turn a hang into a failure; a slow machine makes them longer, never the result different.
private let hangGuard: Duration = .seconds(300)

/// Fires once; `wait()` returns when it has fired.
private final class Latch: @unchecked Sendable {
    private let fired = Box(false)
    func fire() { fired.set(true) }
    var isFired: Bool { fired.get() }
    @discardableResult
    func wait() async -> Bool { await pollUntil(timeout: hangGuard) { fired.get() } }
}

/// What the destination saw (uploads started and in flight), and the most bytes the staging folder held at any read,
/// export or upload.
private final class PipelineProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let staging: URL
    private var inFlight = 0
    private var started = 0
    private var peak: Int64 = 0

    init(staging: URL) { self.staging = staging }

    var uploadsInFlight: Int { lock.withLock { inFlight } }
    var uploadsStarted: Int { lock.withLock { started } }
    var peakStagedBytes: Int64 { lock.withLock { peak } }

    func readStarted() { sampleStaging() }

    /// Counts the upload as in flight while `body` runs; `body` gets the upload's zero-based number.
    func upload(_ body: (Int) async -> Void) async {
        let index = lock.withLock { () -> Int in
            inFlight += 1
            started += 1
            return started - 1
        }
        sampleStaging()
        await body(index)
        lock.withLock { inFlight -= 1 }
    }

    func sampleStaging() {
        let files = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        var total: Int64 = 0
        while let url = files?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        lock.withLock { peak = max(peak, total) }
    }
}

/// A cloud folder read over a slow link. While reads are held, each read waits for `releaseReads()` (or the hang guard), and
/// gives up with `cancelled` when the engine cancels its control or its task, as a real download does.
private final class SlowCloudFolder: FolderImportSource, @unchecked Sendable {
    private let inner: LocalFolderSource
    private let probe: PipelineProbe
    private let lock = NSLock()
    private var readPaths: [String] = []
    private var exported = 0
    private var holding = false
    private var holdingExports = false
    private var exportsWaiting = 0
    private var waiting: [String] = []
    private var stopped = 0

    init(_ folder: ImportFolder, probe: PipelineProbe) {
        inner = folder.source()
        self.probe = probe
    }

    var id: SourceID { inner.id }
    var reads: [String] { lock.withLock { readPaths } }
    var exports: Int { lock.withLock { exported } }
    /// Reads waiting for `releaseReads()` now.
    var heldReads: Int { lock.withLock { waiting.count } }
    var heldPaths: [String] { lock.withLock { waiting } }
    /// Held reads that ended because the engine told them to stop.
    var cancelledReads: Int { lock.withLock { stopped } }
    func holdReads() { lock.withLock { holding = true } }
    func releaseReads() { lock.withLock { holding = false } }
    /// Exports from now on wait like held reads, until `releaseExports()`.
    func holdExports() { lock.withLock { holdingExports = true } }
    func releaseExports() { lock.withLock { holdingExports = false } }
    var heldExports: Int { lock.withLock { exportsWaiting } }

    func probe() async throws { try await inner.probe() }
    func listFiles() async throws -> [FolderFileEntry] { try await inner.listFiles() }

    func inspect(relativePath: String, uti: String, mediaType: MediaType, control: ExportControl) async throws -> InspectedFile {
        lock.withLock { readPaths.append(relativePath) }
        probe.readStarted()
        if lock.withLock({ holding }) {
            lock.withLock { waiting.append(relativePath) }
            defer { lock.withLock { waiting.removeAll { $0 == relativePath } } }
            // A hold nobody releases ends at the hang guard, so a test that waits for the wrong thing fails instead of hanging.
            let deadline = ContinuousClock.now + hangGuard
            while lock.withLock({ holding }), ContinuousClock.now < deadline {
                if control.isCancelled || Task.isCancelled {
                    lock.withLock { stopped += 1 }
                    throw SourceError.cancelled
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        return try await inner.inspect(relativePath: relativePath, uti: uti, mediaType: mediaType, control: control)
    }

    func exportResource(_ locator: ResourceLocator, to destination: URL, control: ExportControl) async throws -> ExportedFile {
        lock.withLock { exported += 1 }
        if lock.withLock({ holdingExports }) {
            lock.withLock { exportsWaiting += 1 }
            defer { lock.withLock { exportsWaiting -= 1 } }
            let deadline = ContinuousClock.now + hangGuard
            while lock.withLock({ holdingExports }), ContinuousClock.now < deadline {
                if control.isCancelled || Task.isCancelled { throw SourceError.cancelled }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let file = try await inner.exportResource(locator, to: destination, control: control)
        probe.sampleStaging()
        return file
    }
}

/// Download and upload of a cloud import overlap: a round reads and stages the next batch while the upload pass sends the
/// batch staged before it. Each test starts with the first batch read and staged and nothing uploaded, then lets the engine
/// run with uploads allowed and watches the overlap through signals.
@Suite struct PipelinedImportTests {
    private static let fileSize = 1_000
    private static let files = 6

    private struct Pipeline {
        let h: Harness
        let source: SlowCloudFolder
        let probe: PipelineProbe
        let id: SourceID
    }

    /// Six photos in batches of two from a slow cloud folder, a staging limit of three files. A first cycle with uploads held
    /// lists the folder and reads and stages the first batch; the engine is then rebuilt with uploads allowed.
    private func pipeline() async throws -> Pipeline {
        let h = try await Harness { tuning in
            tuning.importBatchGroups = 2
            tuning.maxCycleIterations = 2
        }
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        try await h.update { $0.stagingSoftLimitBytes = Int64(3 * Self.fileSize) }
        let folder = try ImportFolder()
        for index in 0..<Self.files {
            let date = h.clock.now.addingTimeInterval(-86_400 * Double(index + 2))
            try folder.add("p\(index).jpg", String(repeating: "\(index)", count: Self.fileSize), metadata: ImportFolder.photo(at: date))
        }
        let probe = PipelineProbe(staging: h.staging)
        let source = SlowCloudFolder(folder, probe: probe)
        h.system.set(SystemSnapshot(networkAvailable: false))
        let id = try await h.coordinator.startImport(
            source: source, kind: .googleDrive, displayName: "Trip", config: SourceConfig(account: "someone@example.com", remoteItems: [""]))
        _ = await h.run()
        try #require(source.reads == ["p0.jpg", "p1.jpg"], "the first cycle reads the first batch")
        try #require(source.exports == 2, "and stages it")
        try #require(await h.drive.files.isEmpty)
        h.system.set(SystemSnapshot())
        h.tuning.maxCycleIterations = EngineTuning().maxCycleIterations
        try await h.restart()
        try await h.coordinator.start()
        return Pipeline(h: h, source: source, probe: probe, id: id)
    }

    /// Every file reached Drive exactly once and staging is empty.
    private func expectAllDeliveredOnce(_ p: Pipeline, sourceFiles: Int = PipelinedImportTests.files) async throws {
        let names = await p.h.fileNames(p.h.drive)
        #expect(names.count == sourceFiles, "\(names.count) files at Drive")
        #expect(Set(names).count == names.count, "no file was uploaded twice")
        #expect(try p.h.assets(of: p.id).count == sourceFiles)
        #expect(try p.h.jobs(.done).count == sourceFiles)
        #expect(try p.h.source(p.id)?.status == .completed)
        #expect(p.h.stagingFiles().isEmpty, "nothing is left in staging")
    }

    @Test func theNextBatchIsReadWhileTheLastOneUploads() async throws {
        let p = try await pipeline()
        let probe = p.probe
        let source = p.source
        // The next read waits until it is released, and the first upload releases it only once it sees the read in hand
        // while it is itself in flight. Run one after the other, the read would wait for the upload and the upload for the read.
        let overlapped = Box<[String]?>(nil)
        source.holdReads()
        await p.h.drive.setUploadHook { _ in
            await probe.upload { index in
                guard index == 0 else { return }
                if await pollUntil(timeout: hangGuard, { source.heldReads > 0 }) { overlapped.set(source.heldPaths) }
                source.releaseReads()
            }
        }
        let outcome = await p.h.run()
        guard case .completed = outcome else {
            Issue.record("expected a completed cycle, got \(outcome)")
            return
        }
        #expect(overlapped.get() == ["p2.jpg"], "the second batch's first read was in hand while the first batch uploaded")
        #expect(source.reads == (0..<Self.files).map { "p\($0).jpg" }, "every file is read once, in order")
        // The staging limit admits exports while staged + in-flight bytes are below it; at most two exports run at once.
        let bound = Int64(3 * Self.fileSize + 2 * Self.fileSize)
        #expect(probe.peakStagedBytes <= bound, "staging held \(probe.peakStagedBytes) bytes, bound \(bound)")
        try await expectAllDeliveredOnce(p)
    }

    @Test func pauseDuringTheOverlapStartsNoFurtherReadExportOrUpload() async throws {
        let p = try await pipeline()
        let probe = p.probe
        let uploadsGo = Latch()
        await p.h.drive.setUploadHook { _ in await probe.upload { _ in await uploadsGo.wait() } }
        p.source.holdReads()
        let coordinator = p.h.coordinator
        let cycle = Task { await coordinator.run(trigger: .manual) }
        let overlapping = await pollUntil(timeout: hangGuard) { probe.uploadsInFlight == 2 && p.source.heldReads == 1 }
        try #require(overlapping, "both uploads of the first batch are in flight while the next read is in hand")
        await coordinator.pauseAll()
        let reads = p.source.reads.count
        let exports = p.source.exports
        let uploads = probe.uploadsStarted
        uploadsGo.fire()
        p.source.releaseReads()
        let outcome = await cycle.value
        #expect(outcome == .paused)
        #expect(p.source.reads.count == reads, "no read starts after the pause")
        #expect(p.source.exports == exports, "no export starts after the pause")
        #expect(probe.uploadsStarted == uploads, "no upload starts after the pause")
        #expect(await p.h.drive.files.count == 2, "the uploads in flight finish")
        await coordinator.resumeAll()
        await p.h.settle()
        try await expectAllDeliveredOnce(p)
    }

    @Test func cancelDuringTheOverlapStopsTheReadAtOnceAndKeepsWhatUploaded() async throws {
        let p = try await pipeline()
        let probe = p.probe
        let uploadsGo = Latch()
        await p.h.drive.setUploadHook { _ in await probe.upload { _ in await uploadsGo.wait() } }
        p.source.holdReads()
        let coordinator = p.h.coordinator
        let cycle = Task { await coordinator.run(trigger: .manual) }
        let overlapping = await pollUntil(timeout: hangGuard) { probe.uploadsInFlight == 2 && p.source.heldReads == 1 }
        try #require(overlapping, "both uploads of the first batch are in flight while the next read is in hand")
        let exports = p.source.exports
        let id = p.id
        let cancel = Task { try await coordinator.cancelImport(id) }
        let stopped = await pollUntil(timeout: hangGuard) { p.source.cancelledReads == 1 }
        #expect(stopped, "the read in hand is told to stop")
        #expect(probe.uploadsInFlight == 2, "while the uploads are still in flight")
        #expect(try p.h.source(id)?.config.cancelRequested == true, "the cancel is stored at once")
        uploadsGo.fire()
        try await cancel.value
        _ = await cycle.value
        #expect(try p.h.source(id)?.status == .cancelled)
        #expect(p.source.reads == ["p0.jpg", "p1.jpg", "p2.jpg"], "no file is read after the cancel")
        #expect(p.source.exports == exports, "nothing of the cancelled import is downloaded again")
        #expect(await p.h.drive.files.count == 2, "the uploads in flight finish and stay")
        #expect(try p.h.jobs(.done).count == 2)
        #expect(try p.h.jobs(.pending).isEmpty && (try p.h.jobs(.uploading).isEmpty))
        #expect(p.h.stagingFiles().isEmpty)
    }

    @Test func aCrashWhileReadingBesideUploadsRecovers() async throws {
        let p = try await pipeline()
        let probe = p.probe
        let source = p.source
        let crashed = Latch()
        // The read half dies when it records the second batch's first group while the first batch is uploading: the read waits
        // until the first upload is in flight, and that upload waits for the crash.
        p.h.injector.onReach { point in
            guard point == .afterImportGroupCommit, !crashed.isFired, probe.uploadsInFlight > 0 else { return }
            crashed.fire()
            throw SimulatedCrash(point: point.rawValue)
        }
        source.holdReads()
        await p.h.drive.setUploadHook { _ in
            await probe.upload { index in
                guard index == 0 else { return }
                _ = await pollUntil(timeout: hangGuard) { source.heldReads > 0 }
                source.releaseReads()
                await crashed.wait()
            }
        }
        let outcome = await p.h.run()
        #expect(crashed.isFired, "the crash came while uploads were in flight")
        guard case .failed = outcome else {
            Issue.record("expected the cycle to stop on the crash, got \(outcome)")
            return
        }
        p.h.injector.onReach(nil)
        try await p.h.restart()
        try await p.h.coordinator.start()
        await p.h.settle()
        try await expectAllDeliveredOnce(p)
    }

    @Test func aCrashWhileUploadingBesideAReadRecovers() async throws {
        let p = try await pipeline()
        let probe = p.probe
        let source = p.source
        let crashed = Latch()
        source.holdReads()
        // The upload half dies after Drive took the first file and before the engine recorded it, while a read is in hand.
        p.h.injector.onReach { point in
            guard point == .afterUploadBeforeCommit, !crashed.isFired, source.heldReads > 0 else { return }
            crashed.fire()
            throw SimulatedCrash(point: point.rawValue)
        }
        await p.h.drive.setUploadHook { _ in
            await probe.upload { index in
                if index < 2 { _ = await pollUntil(timeout: hangGuard) { source.heldReads > 0 } }
            }
        }
        let outcome = await p.h.run()
        #expect(crashed.isFired, "the crash came while a read was in hand")
        guard case .failed = outcome else {
            Issue.record("expected the cycle to stop on the crash, got \(outcome)")
            return
        }
        #expect(await pollUntil(timeout: hangGuard) { source.cancelledReads == 1 }, "the read in hand was stopped with the cycle")
        source.releaseReads()
        p.h.injector.onReach(nil)
        try await p.h.restart()
        try await p.h.coordinator.start()
        await p.h.settle()
        try await expectAllDeliveredOnce(p)
    }

    @Test func anExportCutOffByAnUploadErrorIsDoneAgainWithoutARelaunch() async throws {
        let p = try await pipeline()
        let probe = p.probe
        let source = p.source
        let crashed = Latch()
        source.holdExports()
        // The upload pass stops on an error while the next batch is being staged beside it; the engine is not rebuilt.
        p.h.injector.onReach { point in
            guard point == .afterUploadBeforeCommit, !crashed.isFired, source.heldExports > 0 else { return }
            crashed.fire()
            throw SimulatedCrash(point: point.rawValue)
        }
        await p.h.drive.setUploadHook { _ in
            await probe.upload { index in
                if index < 2 { _ = await pollUntil(timeout: hangGuard) { source.heldExports > 0 } }
            }
        }
        let outcome = await p.h.run()
        #expect(crashed.isFired, "the error came while an export was in hand")
        guard case .failed = outcome else {
            Issue.record("expected the cycle to stop on the error, got \(outcome)")
            return
        }
        source.releaseExports()
        p.h.injector.onReach(nil)
        await p.h.settle()
        try await expectAllDeliveredOnce(p)
    }

    @Test func aWaitingCommandRunsBeforeTheNextExport() async throws {
        let p = try await pipeline()
        p.h.tuning.maxConcurrentExports = 1
        try await p.h.restart()
        let source = p.source
        source.holdExports()
        let coordinator = p.h.coordinator
        let cycle = Task { await coordinator.run(trigger: .manual) }
        try #require(await pollUntil(timeout: hangGuard) { source.heldExports == 1 }, "an export of the second batch is in hand")
        let started = source.exports
        let seen = Task { await coordinator.exclusive { source.exports } }
        try #require(await pollUntil(timeout: hangGuard) { await coordinator.lane.hasWaitingCommands })
        source.releaseExports()
        #expect(await seen.value == started, "the command ran before the next export started")
        _ = await cycle.value
        await p.h.settle()
        try await expectAllDeliveredOnce(p)
    }
}
