import Foundation
import Testing
@testable import PhotoVaultAppSupport

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

struct TriggerDebouncerTests {
    @Test func burstFiresOnceAfterQuietPeriod() async throws {
        let counter = Counter()
        let debouncer = TriggerDebouncer(quiet: 0.1, maxWait: 1) { counter.increment() }
        for _ in 0..<5 {
            await debouncer.signal()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(counter.count == 0)
        try await Task.sleep(for: .milliseconds(300))
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
        #expect(counter.count >= 1)
        await debouncer.cancel()
    }

    @Test func separateBurstsFireSeparately() async throws {
        let counter = Counter()
        let debouncer = TriggerDebouncer(quiet: 0.05, maxWait: 0.5) { counter.increment() }
        await debouncer.signal()
        try await Task.sleep(for: .milliseconds(250))
        await debouncer.signal()
        try await Task.sleep(for: .milliseconds(250))
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
