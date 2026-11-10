import Foundation

/// Coalesces bursts of change signals (Photos library changes, FR-14): fires once after `quiet`
/// seconds without a new signal, but never later than `maxWait` after the first signal of a burst.
public actor TriggerDebouncer {
    /// Monotonic time in seconds, and a sleep until such a time that throws when its task is cancelled.
    /// The app uses the continuous clock; tests pass one they move by hand.
    struct TimeSource: Sendable {
        var now: @Sendable () -> TimeInterval
        var sleep: @Sendable (_ until: TimeInterval) async throws -> Void

        static var continuous: TimeSource {
            let origin = ContinuousClock.now
            return TimeSource(
                now: { TriggerDebouncer.seconds(origin.duration(to: .now)) },
                sleep: { try await Task.sleep(until: origin.advanced(by: .seconds($0)), clock: .continuous) })
        }
    }

    private let quiet: TimeInterval
    private let maxWait: TimeInterval
    private let timer: TimeSource
    private let fire: @Sendable () async -> Void
    private var burstStart: TimeInterval?
    private var pending: Task<Void, Never>?
    /// The pending fire is already pinned to the burst's `maxWait` deadline; later signals keep it.
    private var pinnedToDeadline = false

    public init(quiet: TimeInterval = 30, maxWait: TimeInterval = 60, fire: @escaping @Sendable () async -> Void) {
        self.init(quiet: quiet, maxWait: maxWait, timer: .continuous, fire: fire)
    }

    init(quiet: TimeInterval, maxWait: TimeInterval, timer: TimeSource, fire: @escaping @Sendable () async -> Void) {
        self.quiet = quiet
        self.maxWait = max(quiet, maxWait)
        self.timer = timer
        self.fire = fire
    }

    public func signal() {
        let now = timer.now()
        let start = burstStart ?? now
        burstStart = start
        if pinnedToDeadline, pending != nil { return }
        let deadline = start + maxWait
        // The fire time is fixed here, so a fire task that starts late still fires on time.
        let fireAt = min(now + quiet, deadline)
        pinnedToDeadline = deadline - now <= quiet
        pending?.cancel()
        pending = Task { [fire, timer] in
            do { try await timer.sleep(fireAt) } catch { return }
            await self.deliver(fire)
        }
    }

    public func cancel() {
        pending?.cancel()
        pending = nil
        burstStart = nil
        pinnedToDeadline = false
    }

    private func deliver(_ fire: @Sendable () async -> Void) async {
        guard !Task.isCancelled else { return }
        burstStart = nil
        pending = nil
        pinnedToDeadline = false
        await fire()
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
