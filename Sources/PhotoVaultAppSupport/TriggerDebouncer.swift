import Foundation

/// Coalesces bursts of change signals (Photos library changes, FR-14): fires once after `quiet`
/// seconds without a new signal, but never later than `maxWait` after the first signal of a burst.
public actor TriggerDebouncer {
    private let quiet: TimeInterval
    private let maxWait: TimeInterval
    private let fire: @Sendable () async -> Void
    private var burstStart: ContinuousClock.Instant?
    private var pending: Task<Void, Never>?

    public init(quiet: TimeInterval = 30, maxWait: TimeInterval = 60, fire: @escaping @Sendable () async -> Void) {
        self.quiet = quiet
        self.maxWait = max(quiet, maxWait)
        self.fire = fire
    }

    public func signal() {
        let now = ContinuousClock.now
        let start = burstStart ?? now
        burstStart = start
        let elapsed = Self.seconds(start.duration(to: now))
        let delay = max(0, min(quiet, maxWait - elapsed))
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
    }

    private func deliver(_ fire: @Sendable () async -> Void) async {
        guard !Task.isCancelled else { return }
        burstStart = nil
        pending = nil
        await fire()
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
