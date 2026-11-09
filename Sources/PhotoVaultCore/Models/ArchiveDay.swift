import Foundation

/// A calendar day in the archive timezone (spec 8.6), formatted `YYYY-MM-DD`.
public struct ArchiveDay: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents(year: year, month: month, day: day)
        components.calendar = Calendar(identifier: .gregorian)
        guard components.isValidDate else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `YYYY-MM-DD`.
    public init?(string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// The day `date` falls on in `timeZone`.
    public init(date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        year = c.year!
        month = c.month!
        day = c.day!
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = ArchiveDay(string: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid day \(value)"))
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var yearString: String { String(format: "%04d", year) }
    public var monthString: String { String(format: "%02d", month) }

    /// Start of the next day in `timeZone` (used for the FR-83 "day ended ≥ 6 h" rule).
    public func endDate(in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.date(from: DateComponents(year: year, month: month, day: day))!
        return calendar.date(byAdding: .day, value: 1, to: start)!
    }

    public static func < (lhs: ArchiveDay, rhs: ArchiveDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// Placement day: a known archive day or `unknown` when the asset has no date (FR-40).
public enum PlacementDay: Hashable, Codable, Sendable, CustomStringConvertible {
    case day(ArchiveDay)
    case unknown

    public static let unknownToken = "unknown"

    public init?(string: String) {
        if string == Self.unknownToken { self = .unknown } else if let d = ArchiveDay(string: string) { self = .day(d) } else { return nil }
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = PlacementDay(string: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid placement day"))
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public var description: String {
        switch self {
        case .day(let d): d.description
        case .unknown: Self.unknownToken
        }
    }

    public var archiveDay: ArchiveDay? {
        if case .day(let d) = self { return d }
        return nil
    }
}

/// Where every file of an asset lives, fixed once (spec 8.1).
public struct Placement: Hashable, Codable, Sendable {
    public var category: AssetCategory
    public var day: PlacementDay
    /// `YYYY-MM-DD HH.mm.ss_<originalStem>` with any collision suffix, shared by all destinations.
    public var nameStem: String

    public init(category: AssetCategory, day: PlacementDay, nameStem: String) {
        self.category = category
        self.day = day
        self.nameStem = nameStem
    }
}
