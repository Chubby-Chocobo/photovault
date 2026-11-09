import Foundation

/// The persistable part of the daily cap: the rolling 24-hour upload entries.
public struct DailyCapState: Equatable, Sendable, Codable {
    public var entries: [DailyUploadCap.Entry]
    public init(entries: [DailyUploadCap.Entry] = []) { self.entries = entries }
}

/// Rolling 24-hour upload byte counter (FR-49). Bytes are reserved when an upload starts so
/// concurrent uploads cannot overshoot; the owner of the destination persists `state` on change.
public struct DailyUploadCap: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Codable {
        public var at: Date
        public var bytes: Int64
        public init(at: Date, bytes: Int64) { self.at = at; self.bytes = bytes }
    }

    public static let defaultLimit: Int64 = 700 * 1_000_000_000
    public static let window: TimeInterval = 24 * 3600

    public let limit: Int64
    public private(set) var entries: [Entry]

    public init(limit: Int64 = DailyUploadCap.defaultLimit, entries: [Entry] = []) {
        self.limit = limit
        self.entries = entries
    }

    public init(limit: Int64 = DailyUploadCap.defaultLimit, state: DailyCapState) {
        self.init(limit: limit, entries: state.entries)
    }

    public var state: DailyCapState { DailyCapState(entries: entries) }

    public func usage(at now: Date) -> Int64 {
        entries.filter { now.timeIntervalSince($0.at) < Self.window }.reduce(0) { $0 + $1.bytes }
    }

    public func canUpload(bytes: Int64, at now: Date) -> Bool { usage(at: now) + bytes <= limit }

    public mutating func record(bytes: Int64, at now: Date) {
        entries.removeAll { now.timeIntervalSince($0.at) >= Self.window }
        entries.append(Entry(at: now, bytes: bytes))
    }

    /// Records `bytes` when they fit under the limit; false (and no change) otherwise.
    public mutating func reserve(bytes: Int64, at now: Date) -> Bool {
        guard canUpload(bytes: bytes, at: now) else { return false }
        record(bytes: bytes, at: now)
        return true
    }

    /// Undoes a `reserve(bytes:at:)` made at the same instant.
    public mutating func release(bytes: Int64, at now: Date) {
        if let index = entries.lastIndex(of: Entry(at: now, bytes: bytes)) { entries.remove(at: index) }
    }
}
