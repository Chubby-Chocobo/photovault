import Foundation

/// Byte token bucket for Drive writes (FR-49, 8.5). Time is always passed in; there is no wall
/// clock inside. Upload requests may drain the bucket; metadata and view writes can only use the
/// part above `metadataReserve`, so uploads win under pressure. A request larger than the whole
/// bucket is admitted when the bucket is full and leaves it in debt that later refills repay.
public struct TokenBucket: Sendable {
    public enum Lane: Sendable, Hashable {
        case upload
        case metadata
    }

    public let capacity: Int64
    public let refillPerHour: Int64
    /// Tokens only the upload lane may take.
    public let metadataReserve: Int64
    private var tokens: Double
    private var lastUpdate: Date?

    public init(capacity: Int64, refillPerHour: Int64, metadataReserveFraction: Double = 0.5) {
        precondition(capacity > 0 && refillPerHour >= 0, "TokenBucket needs capacity > 0 and refill >= 0")
        self.capacity = capacity
        self.refillPerHour = refillPerHour
        self.metadataReserve = Int64(Double(capacity) * min(max(metadataReserveFraction, 0), 1))
        self.tokens = Double(capacity)
    }

    private var refillPerSecond: Double { Double(refillPerHour) / 3600 }

    /// Tokens available at `date` after refilling.
    public func available(at date: Date) -> Int64 {
        Int64(refilled(at: date).tokens.rounded(.down))
    }

    /// Takes `bytes` from `lane` when allowed; otherwise leaves the bucket untouched.
    public mutating func tryConsume(bytes: Int64, lane: Lane = .upload, at date: Date) -> Bool {
        self = refilled(at: date)
        guard bytes > 0 else { return true }
        guard fitsLane(bytes: bytes, lane: lane), tokens >= requiredLevel(bytes: bytes, lane: lane) else { return false }
        tokens -= Double(bytes)
        return true
    }

    /// Seconds until `tryConsume` would succeed: 0 when allowed now, nil when it never will
    /// (no refill, or a metadata request that cannot fit above the reserve).
    public func timeUntilAvailable(bytes: Int64, lane: Lane = .upload, at date: Date) -> TimeInterval? {
        let state = refilled(at: date)
        guard bytes > 0 else { return 0 }
        guard fitsLane(bytes: bytes, lane: lane) else { return nil }
        let deficit = requiredLevel(bytes: bytes, lane: lane) - state.tokens
        if deficit <= 0 { return 0 }
        guard refillPerSecond > 0 else { return nil }
        return deficit / refillPerSecond
    }

    /// Metadata requests larger than the unreserved part of the bucket can never be admitted.
    private func fitsLane(bytes: Int64, lane: Lane) -> Bool {
        lane == .upload || bytes <= capacity - metadataReserve
    }

    /// Token level that must be present before `bytes` may be taken.
    private func requiredLevel(bytes: Int64, lane: Lane) -> Double {
        switch lane {
        case .upload: Double(min(bytes, capacity))
        case .metadata: Double(metadataReserve + min(bytes, capacity - metadataReserve))
        }
    }

    private func refilled(at date: Date) -> TokenBucket {
        var copy = self
        guard let last = lastUpdate else {
            copy.lastUpdate = date
            return copy
        }
        let elapsed = max(0, date.timeIntervalSince(last))
        copy.tokens = min(Double(capacity), tokens + elapsed * refillPerSecond)
        copy.lastUpdate = max(last, date)
        return copy
    }
}

/// Upload volume in a sliding 24 h window (FR-49: 700 GB). An entry counts for exactly `window`
/// seconds after it was recorded.
public struct RollingByteCap: Sendable {
    public struct Entry: Hashable, Sendable {
        public var at: Date
        public var bytes: Int64
        public init(at: Date, bytes: Int64) {
            self.at = at
            self.bytes = bytes
        }
    }

    /// 700 GB (decimal, below the 750 GB Drive limit even when counted in GiB elsewhere).
    public static let defaultLimit: Int64 = 700_000_000_000

    public let limit: Int64
    public let window: TimeInterval
    /// Recorded uploads, oldest first; persisted by the caller across restarts.
    public private(set) var entries: [Entry]

    public init(limit: Int64 = RollingByteCap.defaultLimit, window: TimeInterval = 24 * 3600, entries: [Entry] = []) {
        self.limit = limit
        self.window = window
        self.entries = entries.sorted { $0.at < $1.at }
    }

    public mutating func record(bytes: Int64, at date: Date) {
        guard bytes > 0 else { return }
        let index = entries.firstIndex { $0.at > date } ?? entries.endIndex
        entries.insert(Entry(at: date, bytes: bytes), at: index)
        let horizon = date.addingTimeInterval(-window)
        entries.removeAll { $0.at <= horizon }
    }

    public func usage(at date: Date) -> Int64 {
        let horizon = date.addingTimeInterval(-window)
        return entries.reduce(0) { $1.at > horizon ? $0 + $1.bytes : $0 }
    }

    public func allows(bytes: Int64, at date: Date) -> Bool {
        usage(at: date) + bytes <= limit
    }

    /// Earliest time `bytes` fit under the cap; nil when `bytes` alone exceeds the limit.
    public func nextAvailable(bytes: Int64, at date: Date) -> Date? {
        guard bytes <= limit else { return nil }
        if allows(bytes: bytes, at: date) { return date }
        var used = usage(at: date)
        let horizon = date.addingTimeInterval(-window)
        for entry in entries where entry.at > horizon {
            used -= entry.bytes
            if used + bytes <= limit { return entry.at.addingTimeInterval(window) }
        }
        return nil
    }
}
