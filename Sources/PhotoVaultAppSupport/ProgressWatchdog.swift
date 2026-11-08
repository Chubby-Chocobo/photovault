import Foundation

/// Detects work that stopped making progress: feed it a signature of the observable state; when the
/// signature has not changed for `limit`, the work is stalled.
public struct ProgressWatchdog<Signature: Equatable & Sendable>: Sendable {
    public let limit: TimeInterval
    private var last: Signature?
    private var changedAt: Date

    public init(limit: TimeInterval, now: Date) {
        self.limit = limit
        self.changedAt = now
    }

    /// True when the signature has stayed the same for `limit` seconds or more.
    public mutating func isStalled(_ signature: Signature, now: Date) -> Bool {
        if last != signature {
            last = signature
            changedAt = now
            return false
        }
        return now.timeIntervalSince(changedAt) >= limit
    }
}
