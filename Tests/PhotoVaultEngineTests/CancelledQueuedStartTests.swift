import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}

@Suite struct CancelledQueuedStartTests {
    @Test func aStartCancelledWhileItWaitsInTheLaneRecordsNothing() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        let folder = try ImportFolder()
        let coordinator = h.coordinator
        let gate = Gate()
        let holding = Task { try await coordinator.exclusive { await gate.wait() } }
        try await Task.sleep(for: .milliseconds(200))
        let source = folder.source()
        let start = Task { try await coordinator.startFolderImport(source: source, displayName: "Trip", bookmark: nil) }
        try await Task.sleep(for: .milliseconds(200))
        start.cancel()
        await gate.release()
        try await holding.value
        await #expect(throws: CancellationError.self) { _ = try await start.value }
        #expect(try h.read { db in try SourceRepository.fetchAll(db) }.isEmpty)
    }
}
