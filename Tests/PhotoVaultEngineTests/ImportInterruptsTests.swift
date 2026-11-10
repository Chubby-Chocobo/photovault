import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultEngine

@Suite struct ImportInterruptsTests {
    @Test func theWorkResultIsReturnedWhenNothingCancels() async throws {
        let interrupts = ImportInterrupts()
        let value = try await interrupts.untilCancelled(.folder()) { 42 }
        #expect(value == 42)
    }

    @Test func aCancelOfTheImportEndsTheWaitWithNil() async throws {
        let interrupts = ImportInterrupts()
        let id = SourceID.folder()
        let waiting = Task { try await interrupts.untilCancelled(id) { try await Task.sleep(for: .seconds(30)); return 1 } }
        try await Task.sleep(for: .milliseconds(100))
        interrupts.requestCancel(id)
        #expect(try await waiting.value == nil)
    }

    @Test func cancellingTheCallingTaskEndsTheWaitAndStopsTheWork() async throws {
        let interrupts = ImportInterrupts()
        let started = Date()
        let waiting = Task { try await interrupts.untilCancelled(.folder()) { try await Task.sleep(for: .seconds(30)); return 1 } }
        try await Task.sleep(for: .milliseconds(100))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func aCallerCancelledBeforeTheWaitStartsIsAnsweredAtOnce() async throws {
        let interrupts = ImportInterrupts()
        let returned = Box(false)
        let waiting = Task {
            defer { returned.set(true) }
            // The cancellation is in before the wait begins, so the wait finds its answer already there.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await interrupts.untilCancelled(.folder()) { try await Task.sleep(for: .seconds(30)); return 1 }
        }
        let ended = await eventually(10) { returned.get() }
        #expect(ended, "the wait does not hang when it ended before it began")
        guard ended else { return }
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
    }
}
