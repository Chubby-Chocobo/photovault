import Foundation

/// Rolling 24-hour upload byte counter (FR-49). In-memory; the engine persists `entries` later.
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

    public func usage(at now: Date) -> Int64 {
        entries.filter { now.timeIntervalSince($0.at) < Self.window }.reduce(0) { $0 + $1.bytes }
    }

    public func canUpload(bytes: Int64, at now: Date) -> Bool { usage(at: now) + bytes <= limit }

    public mutating func record(bytes: Int64, at now: Date) {
        entries.removeAll { now.timeIntervalSince($0.at) >= Self.window }
        entries.append(Entry(at: now, bytes: bytes))
    }
}
