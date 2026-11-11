import Foundation
import PhotoVaultCore

/// The time range picker of the History window, in local days.
public enum HistoryTimeRange: String, CaseIterable, Identifiable, Sendable {
    case all, today, last7Days, last30Days, last12Months

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: tr(vi: "Mọi lúc", en: "Any time")
        case .today: tr(vi: "Hôm nay", en: "Today")
        case .last7Days: tr(vi: "7 ngày qua", en: "Last 7 days")
        case .last30Days: tr(vi: "30 ngày qua", en: "Last 30 days")
        case .last12Months: tr(vi: "12 tháng qua", en: "Last 12 months")
        }
    }

    /// `[from, until)`: from the start of the first local day to the start of tomorrow; nil bounds for `all`.
    public func bounds(now: Date, calendar: Calendar) -> (from: Date?, until: Date?) {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)
        switch self {
        case .all: return (nil, nil)
        case .today: return (today, tomorrow)
        case .last7Days: return (calendar.date(byAdding: .day, value: -6, to: today), tomorrow)
        case .last30Days: return (calendar.date(byAdding: .day, value: -29, to: today), tomorrow)
        case .last12Months: return (calendar.date(byAdding: .month, value: -12, to: today), tomorrow)
        }
    }
}

/// What the owner picked in the filter bar of the Photos and Backfill tabs.
public struct HistoryFilterState: Equatable, Sendable {
    public var search = ""
    public var destinationId: DestinationID?
    public var outcome: TransferOutcome?
    public var media: HistoryMediaFilter = .all
    public var timeRange: HistoryTimeRange = .all
    /// Capture dates, both days included; nil when the owner did not limit them.
    public var capturedFrom: Date?
    public var capturedTo: Date?
    public var deletedFromLibraryOnly = false

    public init() {}

    public var isDefault: Bool { self == HistoryFilterState() }

    /// The store filter for `scope`, with day bounds taken in `calendar`'s time zone.
    public func filter(scope: TransferEventFilter.Scope, now: Date, calendar: Calendar) -> TransferEventFilter {
        let range = timeRange.bounds(now: now, calendar: calendar)
        let capturedUntil = capturedTo.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) }
        return TransferEventFilter(
            scope: scope, search: search.trimmingCharacters(in: .whitespacesAndNewlines), destinationId: destinationId,
            outcomes: outcome.map { [$0] } ?? [], media: media, from: range.from, until: range.until,
            capturedFrom: capturedFrom.map { calendar.startOfDay(for: $0) }, capturedUntil: capturedUntil,
            deletedFromLibraryOnly: deletedFromLibraryOnly)
    }
}
