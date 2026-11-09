import Foundation

/// "3 phút trước", "hôm nay 10:05", "hôm qua 21:02", "05/11/2026 08:00".
public enum RelativeTimeText {
    public static func ago(_ date: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let date else { return "Chưa có" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 0 { return "vừa xong" }
        if seconds < 60 { return "vừa xong" }
        if seconds < 3600 { return "\(Int(seconds / 60)) phút trước" }
        if calendar.isDate(date, inSameDayAs: now) { return "hôm nay " + time(date, calendar) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "hôm qua " + time(date, calendar)
        }
        return format("dd/MM/yyyy HH:mm", date, calendar)
    }

    public static func time(_ date: Date, _ calendar: Calendar = .current) -> String { format("HH:mm", date, calendar) }

    /// Heading of an activity day: "Hôm nay", "Hôm qua", "Thứ 7, 07/11/2026".
    public static func dayHeading(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Hôm nay" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Hôm qua"
        }
        let weekday = calendar.component(.weekday, from: date)
        let name = weekday == 1 ? "Chủ nhật" : "Thứ \(weekday)"
        return name + ", " + format("dd/MM/yyyy", date, calendar)
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
