import Foundation

/// Exponential backoff with full jitter, 1 s growing to 30 min (NFR-04). The random source is
/// injected so tests are deterministic.
public struct Backoff: Sendable, Hashable {
    public let base: TimeInterval
    public let cap: TimeInterval

    public init(base: TimeInterval = 1, cap: TimeInterval = 30 * 60) {
        precondition(base > 0 && cap >= base, "Backoff requires 0 < base <= cap")
        self.base = base
        self.cap = cap
    }

    /// Upper bound of the delay for the zero-based `attempt`: `min(cap, base * 2^attempt)`.
    public func ceiling(forAttempt attempt: Int) -> TimeInterval {
        let exponent = Double(min(max(attempt, 0), 40))
        return min(cap, base * pow(2, exponent))
    }

    /// Full jitter: uniform in `0...ceiling(forAttempt:)`.
    public func delay<G: RandomNumberGenerator>(forAttempt attempt: Int, using generator: inout G) -> TimeInterval {
        Double.random(in: 0...ceiling(forAttempt: attempt), using: &generator)
    }

    public func delay(forAttempt attempt: Int) -> TimeInterval {
        var generator = SystemRandomNumberGenerator()
        return delay(forAttempt: attempt, using: &generator)
    }
}
