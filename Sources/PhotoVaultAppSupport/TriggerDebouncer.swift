import Foundation

/// Coalesces bursts of change signals (Photos library changes, FR-14): fires once after `quiet`
/// seconds without a new signal, but never later than `maxWait` after the first signal of a burst.
public actor TriggerDebouncer {
    private let quiet: TimeInterval
    private let maxWait: TimeInterval
    private let fire: @Sendable () async -> Void
    private var burstStart: ContinuousClock.Instant?
    private var pending: Task<Void, Never>?
    /// The pending fire is already pinned to the burst's `maxWait` deadline; later signals keep it.
    private var pinnedToDeadline = false

    public init(quiet: TimeInterval = 30, maxWait: TimeInterval = 60, fire: @escaping @Sendable () async -> Void) {
        self.quiet = quiet
        self.maxWait = max(quiet, maxWait)
        self.fire = fire
    }

    public func signal() {
        let now = ContinuousClock.now
        let start = burstStart ?? now
        burstStart = start
        if pinnedToDeadline, pending != nil { return }
        let elapsed = Self.seconds(start.duration(to: now))
        let untilDeadline = maxWait - elapsed
        let delay = max(0, min(quiet, untilDeadline))
        pinnedToDeadline = untilDeadline <= quiet
        pending?.cancel()
        pending = Task { [fire] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
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
