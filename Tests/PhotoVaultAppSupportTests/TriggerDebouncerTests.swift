import Foundation
import Testing
@testable import PhotoVaultAppSupport

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// Polls until `condition` holds or `timeout` passes; keeps timing tests stable on a loaded machine.
private func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let start = ContinuousClock.now
    while !condition(), start.duration(to: .now) < timeout { try await Task.sleep(for: .milliseconds(10)) }
}

struct TriggerDebouncerTests {
    @Test func burstFiresOnceAfterQuietPeriod() async throws {
        let counter = Counter()
        // Generous quiet period: on a loaded CI runner a 20 ms sleep can take far longer.
        let debouncer = TriggerDebouncer(quiet: 1, maxWait: 10) { counter.increment() }
        for _ in 0..<5 {
            await debouncer.signal()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(counter.count == 0)
        try await eventually { counter.count == 1 }
        #expect(counter.count == 1)
    }

    @Test func maxWaitForcesFireDuringEndlessBurst() async throws {
        let counter = Counter()
        let debouncer = TriggerDebouncer(quiet: 0.2, maxWait: 0.35) { counter.increment() }
        let start = ContinuousClock.now
        while start.duration(to: .now) < .milliseconds(700) {
            await debouncer.signal()
            try await Task.sleep(for: .milliseconds(30))
        }
        try await eventually { counter.count >= 1 }
        #expect(counter.count >= 1)
        await debouncer.cancel()
    }

    /// Signals arriving faster than the fire task can run must not keep cancelling the deadline fire.
    @Test func deadlineFireIsNotCancelledByLaterSignals() async throws {
        let counter = Counter()
        let debouncer = TriggerDebouncer(quiet: 0.05, maxWait: 0.1) { counter.increment() }
        let start = ContinuousClock.now
        while start.duration(to: .now) < .milliseconds(400) {
            await debouncer.signal()
            await Task.yield()
        }
        try await eventually { counter.count >= 1 }
        #expect(counter.count >= 1)
        await debouncer.cancel()
    }

    @Test func separateBurstsFireSeparately() async throws {
        let counter = Counter()
        let debouncer = TriggerDebouncer(quiet: 0.05, maxWait: 0.5) { counter.increment() }
        await debouncer.signal()
        try await eventually { counter.count == 1 }
        #expect(counter.count == 1)
        await debouncer.signal()
        try await eventually { counter.count == 2 }
        #expect(counter.count == 2)
    }

    @Test func cancelDropsPendingFire() async throws {
        let counter = Counter()
        let debouncer = TriggerDebouncer(quiet: 0.1, maxWait: 1) { counter.increment() }
        await debouncer.signal()
        await debouncer.cancel()
        try await Task.sleep(for: .milliseconds(300))
        #expect(counter.count == 0)
    }
}
