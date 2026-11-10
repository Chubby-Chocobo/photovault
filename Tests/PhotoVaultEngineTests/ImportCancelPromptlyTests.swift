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
    private let hold: Bool
    private let delay: Duration

    init(_ folder: ImportFolder, hold: Bool, delay: Duration = .milliseconds(0)) {
        inner = folder.source()
        self.hold = hold
        self.delay = delay
    }

    var id: SourceID { inner.id }
    var reads: Int { lock.withLock { entered } }
    func release() { lock.withLock { released = true } }

    func probe() async throws { try await inner.probe() }
    func listFiles() async throws -> [FolderFileEntry] { try await inner.listFiles() }
    func inspect(relativePath: String, uti: String, mediaType: MediaType, control: ExportControl) async throws -> InspectedFile {
        lock.withLock { entered += 1 }
        while hold, !lock.withLock({ released }) {
            if control.isCancelled { throw SourceError.cancelled }
            try await Task.sleep(for: .milliseconds(10))
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        return try await inner.inspect(relativePath: relativePath, uti: uti, mediaType: mediaType, control: control)
    }
    func exportResource(_ locator: ResourceLocator, to destination: URL, control: ExportControl) async throws -> ExportedFile {
        try await inner.exportResource(locator, to: destination, control: control)
    }
}

private func eventually(_ seconds: Double = 20, _ condition: () async throws -> Bool) async rethrows -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return try await condition()
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
        let holder = Task { try await coordinator.exclusive { try? await Task.sleep(for: .milliseconds(600)) } }
        try await Task.sleep(for: .milliseconds(100))
        let cancel = Task { try await coordinator.cancelImport(id) }
        let stored = try await eventually(0.4) { try h.source(id)?.config.cancelRequested == true }
        try await holder.value
        try await cancel.value
        #expect(stored, "the intent is in the database while the lane is still held")
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
        let readsWhenTheCommandRan = Task { try await coordinator.exclusive { source.reads } }
        let seen = try await readsWhenTheCommandRan.value
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
}
