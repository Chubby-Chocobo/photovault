import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultAppSupport

struct VietnameseFormatTests {
    @Test func groupsThousandsWithDots() {
        #expect(VietnameseFormat.integer(0) == "0")
        #expect(VietnameseFormat.integer(999) == "999")
        #expect(VietnameseFormat.integer(48210) == "48.210")
        #expect(VietnameseFormat.integer(1_234_567) == "1.234.567")
        #expect(VietnameseFormat.integer(-12480) == "-12.480")
    }

    @Test func decimalUsesCommaAndFixedDigits() {
        #expect(VietnameseFormat.decimal(3.2, fractionDigits: 1) == "3,2")
        #expect(VietnameseFormat.decimal(312.44, fractionDigits: 1) == "312,4")
        #expect(VietnameseFormat.decimal(1.42, fractionDigits: 2) == "1,42")
        #expect(VietnameseFormat.decimal(12, fractionDigits: 0) == "12")
        #expect(VietnameseFormat.decimal(12345.6, fractionDigits: 1) == "12.345,6")
    }

    @Test func bytesPickUnitAndPrecision() {
        let gib: Int64 = 1 << 30
        #expect(VietnameseFormat.bytes(0) == "0 B")
        #expect(VietnameseFormat.bytes(512) == "512 B")
        #expect(VietnameseFormat.bytes(1536) == "2 KB")
        #expect(VietnameseFormat.bytes(5 << 20) == "5 MB")
        #expect(VietnameseFormat.bytes(gib * 3 + gib / 5) == "3,2 GB")
        #expect(VietnameseFormat.bytes(gib * 1024 + gib * 430) == "1,42 TB")
        #expect(VietnameseFormat.bytes(-5) == "0 B")
    }

    @Test func gigabytesAlwaysOneDecimal() {
        #expect(VietnameseFormat.gigabytes(15 * (1 << 30)) == "15,0 GB")
    }

    @Test func englishSwapsTheSeparators() {
        L10n.$override.withValue(.en) {
            #expect(VietnameseFormat.integer(1_234_567) == "1,234,567")
            #expect(VietnameseFormat.decimal(12345.6, fractionDigits: 1) == "12,345.6")
            #expect(VietnameseFormat.bytes((1 << 30) * 3 + (1 << 30) / 5) == "3.2 GB")
            #expect(VietnameseFormat.gigabytes(15 * (1 << 30)) == "15.0 GB")
        }
    }
}

struct RelativeTimeTextTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return calendar
    }

    private func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string)!
    }

    @Test func recentTimesCountMinutes() {
        let now = date("2026-11-09T07:32:00Z")
        #expect(RelativeTimeText.ago(now.addingTimeInterval(-20), now: now, calendar: calendar) == "vừa xong")
        #expect(RelativeTimeText.ago(now.addingTimeInterval(-3 * 60), now: now, calendar: calendar) == "3 phút trước")
        #expect(RelativeTimeText.ago(now.addingTimeInterval(-38 * 60), now: now, calendar: calendar) == "38 phút trước")
        #expect(RelativeTimeText.ago(nil, now: now, calendar: calendar) == "Chưa có")
    }

    @Test func olderTimesUseDayNames() {
        let now = date("2026-11-09T07:32:00Z") // 14:32 local
        #expect(RelativeTimeText.ago(date("2026-11-09T03:05:00Z"), now: now, calendar: calendar) == "hôm nay 10:05")
        #expect(RelativeTimeText.ago(date("2026-11-08T14:02:00Z"), now: now, calendar: calendar) == "hôm qua 21:02")
        #expect(RelativeTimeText.ago(date("2026-11-05T01:00:00Z"), now: now, calendar: calendar) == "05/11/2026 08:00")
    }

    @Test func dayHeadings() {
        let now = date("2026-11-09T07:32:00Z")
        #expect(RelativeTimeText.dayHeading(now, now: now, calendar: calendar) == "Hôm nay")
        #expect(RelativeTimeText.dayHeading(date("2026-11-08T05:00:00Z"), now: now, calendar: calendar) == "Hôm qua")
        #expect(RelativeTimeText.dayHeading(date("2026-11-07T05:00:00Z"), now: now, calendar: calendar) == "Thứ 7, 07/11/2026")
        #expect(RelativeTimeText.dayHeading(date("2026-11-01T05:00:00Z"), now: now, calendar: calendar) == "Chủ nhật, 01/11/2026")
    }
}

struct ProgressTextTests {
    @Test func fractionIsClamped() {
        #expect(ProgressText.fraction(done: 0, total: 0) == 0)
        #expect(ProgressText.fraction(done: 12480, total: 48210) > 0.25)
        #expect(ProgressText.fraction(done: 60, total: 50) == 1)
    }

    @Test func etaPicksUnit() {
        #expect(ProgressText.eta(seconds: nil) == "Đang ước tính…")
        #expect(ProgressText.eta(seconds: .infinity) == "Đang ước tính…")
        #expect(ProgressText.eta(seconds: 10) == "Còn khoảng 1 phút")
        #expect(ProgressText.eta(seconds: 25 * 60) == "Còn khoảng 25 phút")
        #expect(ProgressText.eta(seconds: 5 * 3600) == "Còn khoảng 5 giờ")
        #expect(ProgressText.eta(seconds: 6 * 86400) == "Còn khoảng 6 ngày")
    }

    @Test func rateComesFromRemainingAndEta() {
        // 6.100 assets/day: 12.200 remaining in two days.
        #expect(ProgressText.rateCaption(remainingAssets: 12200, etaSeconds: 2 * 86400) == "Ước tính theo số asset: ~6.100 asset/ngày")
        #expect(ProgressText.rateCaption(remainingAssets: 100, etaSeconds: nil) == nil)
        #expect(ProgressText.rateCaption(remainingAssets: 0, etaSeconds: 100) == nil)
    }
}
