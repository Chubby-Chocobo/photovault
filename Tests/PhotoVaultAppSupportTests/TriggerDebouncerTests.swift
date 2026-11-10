import Foundation
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultAppSupport

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// Time that moves only when the test says so, so a slow or loaded machine cannot make a fire early or late.
/// A sleep ends once the time reaches its deadline, or throws when its task is cancelled.
private final class ManualTime: @unchecked Sendable {
    private struct Sleeper { var deadline: TimeInterval; var continuation: CheckedContinuation<Void, any Error> }
    private let lock = NSLock()
    private var current: TimeInterval = 0
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelled: Set<UUID> = []
    private var started = 0

    var source: TriggerDebouncer.TimeSource {
        TriggerDebouncer.TimeSource(now: { self.now }, sleep: { try await self.sleep(until: $0) })
    }

    var now: TimeInterval { lock.withLock { current } }
    /// The deadlines of the sleeps still waiting, earliest first.
    var waiting: [TimeInterval] { lock.withLock { sleepers.values.map(\.deadline).sorted() } }
    /// How many sleeps were started, cancelled ones included.
    var sleeps: Int { lock.withLock { started } }

    func advance(by seconds: TimeInterval) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            current += seconds
            let ready = sleepers.filter { $0.value.deadline <= current }
            ready.keys.forEach { sleepers[$0] = nil }
            return ready.values.map(\.continuation)
        }
        due.forEach { $0.resume() }
    }

    private func sleep(until deadline: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome = lock.withLock { () -> Result<Void, any Error>? in
                    started += 1
                    if cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if current >= deadline { return .success(()) }
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let waiting = lock.withLock { () -> Sleeper? in
                guard let sleeper = sleepers.removeValue(forKey: id) else { cancelled.insert(id); return nil }
                return sleeper
            }
            waiting?.continuation.resume(throwing: CancellationError())
        }
    }
}

/// Lets tasks that were woken run; used only where nothing must happen, so it can never cause a failure.
private func settle() async {
    for _ in 0..<50 { await Task.yield() }
}

/// The times are binary fractions, so the sums the tests compare are exact.
struct TriggerDebouncerTests {
    @Test func burstFiresOnceAfterQuietPeriod() async throws {
        let counter = Counter()
        let time = ManualTime()
        let debouncer = TriggerDebouncer(quiet: 1, maxWait: 10, timer: time.source) { counter.increment() }
        for _ in 0..<5 {
            await debouncer.signal()
            time.advance(by: 0.125)
        }
        // Only the last signal's fire is left, one quiet period after it.
        #expect(await pollUntil { time.waiting == [1.5] })
        time.advance(by: 0.75)
        await settle()
        #expect(counter.count == 0, "the quiet period has not passed")
        time.advance(by: 0.125)
        #expect(await pollUntil { counter.count == 1 })
        time.advance(by: 20)
        await settle()
        #expect(counter.count == 1)
        #expect(time.waiting.isEmpty)
    }

    @Test func maxWaitForcesFireDuringEndlessBurst() async throws {
        let counter = Counter()
        let time = ManualTime()
        let debouncer = TriggerDebouncer(quiet: 0.25, maxWait: 0.375, timer: time.source) { counter.increment() }
        // A signal every 0.0625 s never leaves a quiet gap; the burst fires 0.375 s after its first signal anyway.
        for _ in 0..<10 {
            await debouncer.signal()
            time.advance(by: 0.0625)
        }
        #expect(await pollUntil { counter.count == 1 })
        await settle()
        #expect(counter.count == 1, "the burst that followed has reached neither its quiet period nor its deadline")
        await debouncer.cancel()
    }

    /// A signal whose quiet period would end after the burst's deadline fires at the deadline, not after it.
    @Test func aQuietPeriodThatWouldOverrunTheDeadlineIsCutToIt() async throws {
        let counter = Counter()
        let time = ManualTime()
        let debouncer = TriggerDebouncer(quiet: 0.25, maxWait: 0.375, timer: time.source) { counter.increment() }
        for _ in 0..<3 {
            await debouncer.signal()
            time.advance(by: 0.09375)
        }
        // The last signal came at 0.1875: its quiet period would end at 0.4375, the deadline is 0.375.
        #expect(await pollUntil { time.waiting == [0.375] })
        time.advance(by: 0.09375)
        #expect(await pollUntil { counter.count == 1 })
        #expect(time.now == 0.375)
    }

    /// Signals arriving faster than the fire task can run must not keep cancelling the deadline fire.
    @Test func deadlineFireIsNotCancelledByLaterSignals() async throws {
        let counter = Counter()
        let time = ManualTime()
        let debouncer = TriggerDebouncer(quiet: 0.5, maxWait: 1, timer: time.source) { counter.increment() }
        await debouncer.signal()
        time.advance(by: 0.25)
        await debouncer.signal()
        time.advance(by: 0.25)
        await debouncer.signal()
        #expect(await pollUntil { time.waiting == [1] && time.sleeps == 3 }, "the fire is pinned to the deadline")
        for _ in 0..<50 { await debouncer.signal() }
        await settle()
        #expect(time.sleeps == 3 && time.waiting == [1], "later signals keep the pinned fire instead of replacing it")
        // The deadline passes and signals keep coming before the woken fire task gets to run.
        time.advance(by: 0.5)
        for _ in 0..<200 { await debouncer.signal() }
        #expect(await pollUntil { counter.count >= 1 })
        await debouncer.cancel()
    }

    @Test func separateBurstsFireSeparately() async throws {
        let counter = Counter()
        let time = ManualTime()
        let debouncer = TriggerDebouncer(quiet: 0.25, maxWait: 0.5, timer: time.source) { counter.increment() }
        await debouncer.signal()
        time.advance(by: 0.25)
        #expect(await pollUntil { counter.count == 1 })
        await debouncer.signal()
        #expect(await pollUntil { time.waiting == [0.5] }, "a new burst, timed from its own signal")
        time.advance(by: 0.25)
        #expect(await pollUntil { counter.count == 2 })
    }

    /// A burst after a fire has its own deadline, counted from its own first signal.
    @Test func aBurstAfterAFireStartsItsOwnDeadline() async throws {
        let counter = Counter()
        let time = ManualTime()
        let debouncer = TriggerDebouncer(quiet: 0.25, maxWait: 0.5, timer: time.source) { counter.increment() }
        await debouncer.signal()
        time.advance(by: 0.25)
        #expect(await pollUntil { counter.count == 1 })
        await debouncer.signal()
        time.advance(by: 0.125)
        await debouncer.signal()
        // Second burst from 0.25: deadline 0.75, so the quiet period from 0.375 decides. The first burst's deadline (0.5) is gone.
        #expect(await pollUntil { time.waiting == [0.625] })
        time.advance(by: 0.25)
        #expect(await pollUntil { counter.count == 2 })
    }

    @Test func cancelDropsPendingFire() async throws {
        let counter = Counter()
        let time = ManualTime()
        let debouncer = TriggerDebouncer(quiet: 0.25, maxWait: 1, timer: time.source) { counter.increment() }
        await debouncer.signal()
        await debouncer.cancel()
        time.advance(by: 5)
        await settle()
        #expect(counter.count == 0)
        #expect(time.waiting.isEmpty)
        // The debouncer still works afterwards, and only the new burst fires.
        await debouncer.signal()
        time.advance(by: 0.25)
        #expect(await pollUntil { counter.count == 1 })
        await settle()
        #expect(counter.count == 1)
    }
}
