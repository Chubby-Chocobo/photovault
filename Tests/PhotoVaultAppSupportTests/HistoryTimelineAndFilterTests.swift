import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultAppSupport

@Suite struct HistoryTimelineAndFilterTests {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func utc(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    private func slot(_ text: String, files: Int = 1, bytes: Int64 = 10) -> TimelineSlot {
        TimelineSlot(start: utc(text), files: files, bytes: bytes)
    }

    @Test func slotsFallIntoTheLocalDayAcrossTheDSTChange() {
        // New York moves to summer time on 8 March 2026: that day has 23 hours (05:00Z to 04:00Z).
        let newYork = calendar("America/New_York")
        let slots = [
            slot("2026-03-08T04:45:00Z"),  // 23:45 on the 7th
            slot("2026-03-08T05:00:00Z"),  // midnight of the 8th
            slot("2026-03-09T03:45:00Z"),  // 23:45 on the 8th, summer time
            slot("2026-03-09T04:00:00Z", files: 2, bytes: 5),  // midnight of the 9th
        ]
        let range = (from: utc("2026-03-07T05:00:00Z"), until: utc("2026-03-10T04:00:00Z"))
        let days = HistoryTimeline.days(slots, from: range.from, until: range.until, calendar: newYork)
        #expect(days.map(\.files) == [1, 2, 2])
        #expect(days.map(\.bytes) == [10, 20, 5])
        #expect(days[1].day == utc("2026-03-08T05:00:00Z"))
        #expect(days[2].day == utc("2026-03-09T04:00:00Z"), "the day after the change starts an hour earlier in UTC")
    }

    @Test func quarterHourOffsetsSplitDaysExactly() {
        // Kolkata is UTC+5:30 and Chatham UTC+12:45: their midnights fall on slot boundaries too.
        let kolkata = calendar("Asia/Kolkata")
        let k = HistoryTimeline.days(
            [slot("2026-11-09T18:15:00Z"), slot("2026-11-09T18:30:00Z")],
            from: utc("2026-11-08T18:30:00Z"), until: utc("2026-11-10T18:30:00Z"), calendar: kolkata)
        #expect(k.map(\.files) == [1, 1])
        let chatham = calendar("Pacific/Chatham")
        let c = HistoryTimeline.days(
            [slot("2026-06-10T11:00:00Z"), slot("2026-06-10T11:15:00Z")],
            from: utc("2026-06-09T11:15:00Z"), until: utc("2026-06-11T11:15:00Z"), calendar: chatham)
        #expect(c.map(\.files) == [1, 1])
    }

    @Test func emptyDaysAreShownAsZeroAndTheRangeEndsTomorrow() {
        let vietnam = calendar("Asia/Ho_Chi_Minh")
        let now = utc("2026-11-11T03:00:00Z")  // 10:00 in Vietnam
        let range = HistoryTimeline.range(days: 3, now: now, calendar: vietnam)
        #expect(range.from == utc("2026-11-08T17:00:00Z"))
        #expect(range.until == utc("2026-11-11T17:00:00Z"))
        let days = HistoryTimeline.days([slot("2026-11-10T01:00:00Z", files: 4, bytes: 1 << 30)], from: range.from, until: range.until, calendar: vietnam)
        #expect(days.map(\.files) == [0, 4, 0])
        L10n.$override.withValue(.vi) { #expect(HistoryTimeline.total(days) == "4 file · 1,0 GB") }
        L10n.$override.withValue(.en) { #expect(HistoryTimeline.total(days) == "4 files · 1.0 GB") }
    }

    @Test func timeRangesStartAtLocalMidnight() {
        let vietnam = calendar("Asia/Ho_Chi_Minh")
        let now = utc("2026-11-11T03:00:00Z")
        let today = HistoryTimeRange.today.bounds(now: now, calendar: vietnam)
        #expect(today.from == utc("2026-11-10T17:00:00Z") && today.until == utc("2026-11-11T17:00:00Z"))
        #expect(HistoryTimeRange.last7Days.bounds(now: now, calendar: vietnam).from == utc("2026-11-04T17:00:00Z"))
        #expect(HistoryTimeRange.all.bounds(now: now, calendar: vietnam).from == nil)
    }

    @Test func theFilterStateBuildsTheStoreFilter() {
        let vietnam = calendar("Asia/Ho_Chi_Minh")
        var state = HistoryFilterState()
        #expect(state.isDefault)
        state.search = "  IMG_12 \n"
        state.outcome = .failed
        state.media = .raw
        state.timeRange = .last30Days
        state.capturedFrom = utc("2026-01-01T05:00:00Z")
        state.capturedTo = utc("2026-01-31T20:00:00Z")  // 1 February in Vietnam
        state.deletedFromLibraryOnly = true
        let filter = state.filter(scope: .run(7), now: utc("2026-11-11T03:00:00Z"), calendar: vietnam)
        #expect(filter.scope == .run(7))
        #expect(filter.search == "IMG_12")
        #expect(filter.outcomes == [.failed] && filter.media == .raw && filter.deletedFromLibraryOnly)
        #expect(filter.from == utc("2026-10-12T17:00:00Z") && filter.until == utc("2026-11-11T17:00:00Z"))
        #expect(filter.capturedFrom == utc("2025-12-31T17:00:00Z"))
        #expect(filter.capturedUntil == utc("2026-02-01T17:00:00Z"), "the last picked day is included")
        #expect(!state.isDefault)
    }
}
