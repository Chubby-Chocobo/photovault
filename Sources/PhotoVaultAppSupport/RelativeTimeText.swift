import Foundation
import PhotoVaultCore

/// "3 phút trước", "hôm nay 10:05", "hôm qua 21:02", "05/11/2026 08:00".
public enum RelativeTimeText {
    public static func ago(_ date: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let date else { return tr(vi: "Chưa có", en: "Never") }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return tr(vi: "vừa xong", en: "just now") }
        if seconds < 3600 {
            let minutes = Int(seconds / 60)
            return tr(vi: "\(minutes) phút trước", en: "\(minutes) min ago")
        }
        if calendar.isDate(date, inSameDayAs: now) { return tr(vi: "hôm nay ", en: "today ") + time(date, calendar) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return tr(vi: "hôm qua ", en: "yesterday ") + time(date, calendar)
        }
        return format(tr(vi: "dd/MM/yyyy HH:mm", en: "d MMM yyyy HH:mm"), date, calendar)
    }

    /// "05/11/2026 08:00" ("5 Nov 2026 08:00" in English): a date that is kept, not a time that passes.
    public static func dateTime(_ date: Date, calendar: Calendar = .current) -> String {
        format(tr(vi: "dd/MM/yyyy HH:mm", en: "d MMM yyyy HH:mm"), date, calendar)
    }

    public static func date(_ date: Date, calendar: Calendar = .current) -> String {
        format(tr(vi: "dd/MM/yyyy", en: "d MMM yyyy"), date, calendar)
    }

    public static func time(_ date: Date, _ calendar: Calendar = .current) -> String { format("HH:mm", date, calendar) }

    /// Heading of an activity day: "Hôm nay", "Hôm qua", "Thứ 7, 07/11/2026".
    public static func dayHeading(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return tr(vi: "Hôm nay", en: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return tr(vi: "Hôm qua", en: "Yesterday")
        }
        let weekday = calendar.component(.weekday, from: date)
        let englishDays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let english = englishDays[min(max(weekday, 1), 7) - 1]
        let name = weekday == 1 ? tr(vi: "Chủ nhật", en: english) : tr(vi: "Thứ \(weekday)", en: english)
        return name + ", " + format(tr(vi: "dd/MM/yyyy", en: "d MMM yyyy"), date, calendar)
    }

    private static func format(_ pattern: String, _ date: Date, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
