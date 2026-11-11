import Foundation
import PhotoVaultCore

/// One local day of the timeline chart.
public struct TimelineDay: Identifiable, Hashable, Sendable {
    /// Start of the local day.
    public var day: Date
    public var files: Int
    public var bytes: Int64

    public var id: Date { day }

    public init(day: Date, files: Int, bytes: Int64) {
        self.day = day
        self.files = files
        self.bytes = bytes
    }
}

/// Uploads per local day. The store sums 15-minute slots in UTC; each slot lies inside one local day in every time
/// zone (all offsets are multiples of 15 minutes), so summing slots by the day they start in is exact, DST included.
public enum HistoryTimeline {
    /// `[from, until)` covering the last `days` local days, today included.
    public static func range(days: Int, now: Date, calendar: Calendar) -> (from: Date, until: Date) {
        let today = calendar.startOfDay(for: now)
        let from = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today) ?? today
        let until = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        return (from, until)
    }

    /// Every local day of `[from, until)`, with zero for a day without uploads, oldest first.
    public static func days(_ slots: [TimelineSlot], from: Date, until: Date, calendar: Calendar) -> [TimelineDay] {
        var sums: [Date: (files: Int, bytes: Int64)] = [:]
        for slot in slots {
            let day = calendar.startOfDay(for: slot.start)
            let current = sums[day] ?? (0, 0)
            sums[day] = (current.files + slot.files, current.bytes + slot.bytes)
        }
        var result: [TimelineDay] = []
        var day = calendar.startOfDay(for: from)
        while day < until {
            let sum = sums[day] ?? (0, 0)
            result.append(TimelineDay(day: day, files: sum.files, bytes: sum.bytes))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    /// "1.234 file · 3,0 GB" over the chart.
    public static func total(_ days: [TimelineDay]) -> String {
        let files = days.reduce(0) { $0 + $1.files }
        let bytes = days.reduce(Int64(0)) { $0 + $1.bytes }
        let count = L10n.integer(files)
        return tr(vi: "\(count) file", en: L10n.plural(files, one: "1 file", other: "\(count) files")) + " · " + SizeText.bytes(bytes)
    }
}
