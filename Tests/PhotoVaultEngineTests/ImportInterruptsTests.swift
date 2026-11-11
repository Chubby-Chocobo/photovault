import Foundation
import PhotoVaultCore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// Holds the work until the test opens it, so the work never finishes on its own.
private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if opened { return }; await withCheckedContinuation { waiters.append($0) } }
    func open() { opened = true; waiters.forEach { $0.resume() }; waiters = [] }
}

@Suite struct ImportInterruptsTests {
    @Test func theWorkResultIsReturnedWhenNothingCancels() async throws {
        let interrupts = ImportInterrupts()
        let value = try await interrupts.untilCancelled(.folder()) { 42 }
        #expect(value == 42)
    }

    @Test func aCancelOfTheImportEndsTheWaitWithNil() async throws {
        let interrupts = ImportInterrupts()
        let id = SourceID.folder()
        let gate = Gate()
        defer { Task { await gate.open() } }
        let returned = Box(false)
        let waiting = Task {
            defer { returned.set(true) }
            return try await interrupts.untilCancelled(id) { await gate.wait(); return 1 }
        }
        // Not needed for the outcome: a cancel asked before the wait registers is answered when it does.
        try await Task.sleep(for: .milliseconds(100))
        interrupts.requestCancel(id)
        let ended = await pollUntil { returned.get() }
        #expect(ended, "the wait ends without the work finishing")
        guard ended else { return }
        #expect(try await waiting.value == nil)
    }

    @Test func cancellingTheCallingTaskEndsTheWaitAndStopsTheWork() async throws {
        let interrupts = ImportInterrupts()
        let gate = Gate()
        defer { Task { await gate.open() } }
        let started = Box(false)
        let stopped = Box(false)
        let returned = Box(false)
        let waiting = Task {
            defer { returned.set(true) }
            return try await interrupts.untilCancelled(.folder()) {
                started.set(true)
                // The sleep only guards against a hang; the work ends here because it is cancelled.
                do { try await Task.sleep(for: .seconds(3600)) } catch is CancellationError { stopped.set(true) }
                // After seeing the cancel the work still does not finish, so the wait must end without it.
                await gate.wait()
                return 1
            }
        }
        #expect(await pollUntil { started.get() }, "the work is running when the cancel arrives")
        waiting.cancel()
        let ended = await pollUntil { returned.get() }
        #expect(ended, "the wait ends without the work finishing")
        guard ended else { return }
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
        #expect(await pollUntil { stopped.get() }, "the work is told to stop")
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
        let ended = await pollUntil { returned.get() }
        #expect(ended, "the wait does not hang when it ended before it began")
        guard ended else { return }
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
    }
}
