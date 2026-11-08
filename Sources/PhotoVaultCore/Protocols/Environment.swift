import Foundation

/// Source of the current time; injected so tests control time.
public protocol Clock: Sendable {
    var now: Date { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}

public struct DiskCapacity: Hashable, Sendable {
    /// `volumeAvailableCapacity`: real free space, used for the critical watermark.
    public var available: Int64
    /// `volumeAvailableCapacityForImportantUsage`.
    public var availableForImportantUsage: Int64
    public var total: Int64

    public init(available: Int64, availableForImportantUsage: Int64, total: Int64) {
        self.available = available
        self.availableForImportantUsage = availableForImportantUsage
        self.total = total
    }
}

public protocol DiskSpaceProvider: Sendable {
    func capacity(of url: URL) throws -> DiskCapacity
}

public enum ThermalLevel: Int, Comparable, Codable, Sendable {
    case nominal = 0, fair, serious, critical
    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Power, thermal and network conditions (FR-05, 8.5, NFR-05).
public struct SystemSnapshot: Hashable, Sendable {
    public var onACPower: Bool
    public var lowPowerMode: Bool
    public var thermal: ThermalLevel
    public var networkAvailable: Bool
    public var networkExpensive: Bool
    public var networkConstrained: Bool

    public init(onACPower: Bool = true, lowPowerMode: Bool = false, thermal: ThermalLevel = .nominal,
                networkAvailable: Bool = true, networkExpensive: Bool = false, networkConstrained: Bool = false) {
        self.onACPower = onACPower
        self.lowPowerMode = lowPowerMode
        self.thermal = thermal
        self.networkAvailable = networkAvailable
        self.networkExpensive = networkExpensive
        self.networkConstrained = networkConstrained
    }
}

public protocol SystemConditions: Sendable {
    func snapshot() async -> SystemSnapshot
}

/// UTI questions, answered with `UTType` in production.
public protocol UTIResolver: Sendable {
    func isRaw(_ uti: String) -> Bool
    /// Preferred filename extension, without the dot.
    func preferredExtension(for uti: String) -> String?
}

/// Reverse geocoding by grid cell; only the cell centre is sent (FR-84, FR-85).
public protocol ReverseGeocoding: Sendable {
    func reverseGeocode(cell: GeoCell, locale: String) async throws -> GeoPlace
}

/// Content transform applied before upload (spec §7). Identity in 1.0.
public protocol Transform: Sendable {
    func apply(to content: StagedContent) async throws -> StagedContent
}

public struct IdentityTransform: Transform {
    public init() {}
    public func apply(to content: StagedContent) async throws -> StagedContent { content }
}

public enum LogLevel: String, Sendable, Comparable {
    case debug, info, notice, error, fault
    private var order: Int { [.debug: 0, .info: 1, .notice: 2, .error: 3, .fault: 4][self]! }
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.order < rhs.order }
}

/// Logging sink. Messages must never contain tokens, session URIs, file names, album titles or
/// coordinates (NFR-06, NFR-07); wrap such values in `Redacted`.
public protocol LogSink: Sendable {
    func log(_ level: LogLevel, category: String, _ message: String)
}

public struct NullLogSink: LogSink {
    public init() {}
    public func log(_ level: LogLevel, category: String, _ message: String) {}
}

/// Wraps a sensitive value so string interpolation prints `<redacted>`.
public struct Redacted<Value: Sendable>: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let value: Value
    public init(_ value: Value) { self.value = value }
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
}
