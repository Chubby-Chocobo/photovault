import Foundation

/// Which date an imported file gets (Photos uses the same order for files without EXIF).
public enum ImportDatePolicy {
    /// EXIF `DateTimeOriginal` (+ offset, else the archive timezone), then the video's own date, then
    /// the earlier of the file's creation and modification dates. `date` is nil only when none exists.
    public static func captureDate(metadata: FileMetadata, entry: FolderFileEntry, archiveTimeZone: TimeZone) -> (date: Date?, source: DateSource) {
        if let text = metadata.capture.dateTimeOriginal,
           let date = exifDate(text, offset: metadata.capture.offsetTime, fallback: archiveTimeZone) {
            return (date, .exif)
        }
        if let date = metadata.captureDate { return (date, .video) }
        return (earlier(entry.creationDate, entry.modificationDate), .fileDate)
    }

    private static func earlier(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (a?, b?): min(a, b)
        default: a ?? b
        }
    }

    /// `yyyy:MM:dd HH:mm:ss` in the zone given by `offset` (`+07:00`), else `fallback`.
    static func exifDate(_ text: String, offset: String?, fallback: TimeZone) -> Date? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "-" || $0 == "T" })
        guard parts.count >= 6, let values = Optional(parts.prefix(6).map { Int($0.prefix(4)) }), !values.contains(nil) else { return nil }
        let n = values.map { $0! }
        var components = DateComponents(year: n[0], month: n[1], day: n[2], hour: n[3], minute: n[4], second: n[5])
        guard n[0] >= 1, (1...12).contains(n[1]), (1...31).contains(n[2]), (0...23).contains(n[3]), (0...59).contains(n[4]), (0...59).contains(n[5]) else { return nil }
        let zone = offset.flatMap(timeZone(offset:)) ?? fallback
        components.timeZone = zone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let date = calendar.date(from: components) else { return nil }
        // Calendar is lenient (Feb 30 rolls to March); reject a date that did not survive.
        let back = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard back.year == n[0], back.month == n[1], back.day == n[2] else { return nil }
        return date
    }

    static func timeZone(offset text: String) -> TimeZone? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value == "Z" { return TimeZone(secondsFromGMT: 0) }
        guard let sign = value.first, sign == "+" || sign == "-" else { return nil }
        let digits = value.dropFirst().split(separator: ":")
        guard let hours = digits.first.flatMap({ Int($0) }), hours <= 14 else { return nil }
        let minutes = digits.count > 1 ? Int(digits[1]) ?? 0 : 0
        guard (0..<60).contains(minutes) else { return nil }
        return TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60))
    }
}
