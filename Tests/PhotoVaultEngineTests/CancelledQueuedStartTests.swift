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
    private(set) var entered = false
    func wait() async { entered = true; if open { return }; await withCheckedContinuation { waiters.append($0) } }
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
        let holding = Task { await coordinator.exclusive { await gate.wait() } }
        #expect(await pollUntil { await gate.entered }, "the lane is held")
        let source = folder.source()
        let start = Task { try await coordinator.startFolderImport(source: source, displayName: "Trip", bookmark: nil) }
        #expect(await pollUntil { await coordinator.lane.hasWaitingCommands }, "the start waits in the lane")
        start.cancel()
        await gate.release()
        await holding.value
        await #expect(throws: CancellationError.self) { _ = try await start.value }
        #expect(try h.read { db in try SourceRepository.fetchAll(db) }.isEmpty)
    }
}
