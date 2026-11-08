import Foundation

/// Persists the `NotificationThrottle` as JSON in the container so the 12 hour windows survive a relaunch.
public struct NotificationLedgerFile: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// A missing or unreadable file starts a fresh ledger (worst case: one repeated notification).
    public func load() -> NotificationThrottle {
        guard let data = try? Data(contentsOf: url), let ledger = try? JSONDecoder.iso.decode(NotificationThrottle.self, from: data) else {
            return NotificationThrottle()
        }
        return ledger
    }

    public func save(_ throttle: NotificationThrottle) throws {
        let data = try JSONEncoder.iso.encode(throttle)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
