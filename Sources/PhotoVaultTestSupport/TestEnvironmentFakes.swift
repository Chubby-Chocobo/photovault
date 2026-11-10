import CryptoKit
import Foundation
import PhotoVaultCore

/// Mutable clock for tests.
public final class TestClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date = Date(timeIntervalSince1970: 1_793_000_000)) { current = start }

    public var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }

    public func set(_ date: Date) {
        lock.lock()
        current = date
        lock.unlock()
    }
}

/// Disk capacity that tests change at will.
public final class FakeDiskSpace: DiskSpaceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var value: DiskCapacity

    public init(available: Int64 = 500 * GlobalSettings.GiB, total: Int64 = 1000 * GlobalSettings.GiB) {
        value = DiskCapacity(available: available, availableForImportantUsage: available, total: total)
    }

    public func set(available: Int64, important: Int64? = nil) {
        lock.lock()
        value.available = available
        value.availableForImportantUsage = important ?? available
        lock.unlock()
    }

    public func capacity(of url: URL) throws -> DiskCapacity {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

public final class FakeSystemConditions: SystemConditions, @unchecked Sendable {
    private let lock = NSLock()
    private var value: SystemSnapshot

    public init(_ snapshot: SystemSnapshot = SystemSnapshot()) { value = snapshot }

    public func set(_ snapshot: SystemSnapshot) {
        lock.lock()
        value = snapshot
        lock.unlock()
    }

    public func snapshot() async -> SystemSnapshot { current }

    public var current: SystemSnapshot {
        lock.withLock { value }
    }
}

/// UTI table covering the formats the spec names; production uses `UTType`.
public struct FakeUTIResolver: UTIResolver {
    public static let table: [String: (ext: String, raw: Bool)] = [
        "public.heic": ("heic", false),
        "public.jpeg": ("jpeg", false),
        "public.png": ("png", false),
        "com.apple.quicktime-movie": ("mov", false),
        "public.mpeg-4": ("mp4", false),
        "com.sony.arw-raw-image": ("arw", true),
        "com.nikon.raw-image": ("nef", true),
        "com.canon.cr3-raw-image": ("cr3", true),
        "com.adobe.raw-image": ("dng", true),
        "public.json": ("json", false),
    ]

    public init() {}
    public func isRaw(_ uti: String) -> Bool { Self.table[uti]?.raw ?? false }
    public func preferredExtension(for uti: String) -> String? { Self.table[uti]?.ext }
}

/// Records log lines so tests can assert that secrets never appear.
public final class RecordingLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    public init() {}

    public func log(_ level: LogLevel, category: String, _ message: String) {
        lock.lock()
        storage.append("[\(level.rawValue)] \(category): \(message)")
        lock.unlock()
    }

    public var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func contains(_ needle: String) -> Bool { lines.contains { $0.contains(needle) } }
}

/// Helpers to create staged files in tests.
public enum TestFiles {
    public static func temporaryDirectory(_ name: String = "pv") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func hashes(of data: Data) -> (md5: String, sha256: String) {
        (Insecure.MD5.hash(data: data).hexString, SHA256.hash(data: data).hexString)
    }

    public static func staged(_ data: Data, in directory: URL, name: String = UUID().uuidString) throws -> StagedContent {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        let h = hashes(of: data)
        return StagedContent(file: url, size: Int64(data.count), md5: h.md5, sha256: h.sha256)
    }
}

/// Geocoder answering from a table; counts requests (FR-84 throttle tests).
public actor FakeGeocoder: ReverseGeocoding {
    private var places: [String: GeoPlace] = [:]
    public private(set) var requests: [(cell: GeoCell, locale: String)] = []
    public var failure: (any Error)?
    private var held: Set<GeoCell> = []

    public struct Held: Error, Hashable {}

    public init() {}

    /// Requests for `cell` fail until `release`, as if the geocoder had no answer for it yet.
    public func hold(_ cell: GeoCell) { held.insert(cell) }
    public func release(_ cell: GeoCell) { held.remove(cell) }

    public func set(_ place: GeoPlace, for cell: GeoCell, locale: String) {
        places["\(cell.key)|\(locale)"] = place
    }

    public func setFailure(_ error: (any Error)?) { failure = error }

    public func reverseGeocode(cell: GeoCell, locale: String) async throws -> GeoPlace {
        requests.append((cell, locale))
        if let failure { throw failure }
        if held.contains(cell) { throw Held() }
        return places["\(cell.key)|\(locale)"] ?? GeoPlace()
    }

    public var requestCount: Int { requests.count }
}
