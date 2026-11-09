import Foundation
import PhotoVaultCore

/// Token bucket shared by every Drive write call (create, update, move, shortcut, metadata, upload
/// session start) (FR-49). Metadata calls use the low-priority lane. One token is one call.
public actor DriveWriteLimiter {
    /// Burst of 30 calls, refilled at 5 calls/second; the final rate is set after the Drive limits check (M0-3).
    public static func standard() -> DriveWriteLimiter { DriveWriteLimiter(capacity: 30, refillPerSecond: 5) }

    private var bucket: TokenBucket
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(capacity: Int64, refillPerSecond: Int64, metadataReserveFraction: Double = 0.5,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        bucket = TokenBucket(capacity: capacity, refillPerHour: refillPerSecond * 3600, metadataReserveFraction: metadataReserveFraction)
        self.now = now
        self.sleep = sleep
    }

    /// Returns once a write call may be sent; throws only when cancelled.
    public func acquire(lane: TokenBucket.Lane) async throws {
        while true {
            try Task.checkCancellation()
            let instant = now()
            if bucket.tryConsume(bytes: 1, lane: lane, at: instant) { return }
            let wait = bucket.timeUntilAvailable(bytes: 1, lane: lane, at: instant) ?? 1
            try await sleep(max(wait, 0.01))
        }
    }
}
