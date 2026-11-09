import Foundation
import PhotoVaultCore

/// One line of `photovault.log`: `<ISO date> [LEVEL] category: message`. A line that does not
/// follow the format is kept whole in `message`.
public struct LogEntry: Identifiable, Equatable, Sendable {
    /// The line itself, plus a counter for identical lines: stays the same across reloads, so rows
    /// do not jump while the log grows.
    public var id: String
    public var date: Date?
    public var level: LogLevel?
    public var category: String
    public var message: String
    public var raw: String
    /// `raw` folded for search, computed once off the main thread.
    var folded: String = ""
}

/// Which lines the log window shows. `standard` hides the per-request detail lines.
public enum LogLevelFilter: String, CaseIterable, Identifiable, Sendable {
    case standard, problems, everything

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .standard: tr(vi: "Thông thường", en: "Normal")
        case .problems: tr(vi: "Cảnh báo & lỗi", en: "Warnings & errors")
        case .everything: tr(vi: "Tất cả chi tiết", en: "Everything")
        }
    }

    public func matches(_ level: LogLevel?) -> Bool {
        switch self {
        case .standard: (level ?? .info) >= .info
        case .problems: (level ?? .info) >= .notice
        case .everything: true
        }
    }
}

/// Reads the rotated log files written by `RotatingFileLog` for the in-app log window: newest
/// lines first, across `photovault.log` and `photovault.1.log`… up to `limit` lines.
public struct LogReader: Sendable {
    public static let defaultLimit = 5000

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The current file's size and modification date: the window reloads when it changes.
    public func stamp() -> String? {
        let url = directory.appendingPathComponent("photovault.log")
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        return "\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    /// Newest first.
    public func read(limit: Int = LogReader.defaultLimit) -> [LogEntry] {
        var entries: [LogEntry] = []
        var seen: [String: Int] = [:]
        for index in 0..<RotatingFileLog.fileCount where entries.count < limit {
            let name = index == 0 ? "photovault.log" : "photovault.\(index).log"
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { continue }
            // Only "\n" ends a line: messages may hold other line separators.
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines.reversed() where entries.count < limit {
                let text = String(line)
                let repeats = seen[text, default: 0]
                seen[text] = repeats + 1
                var entry = Self.parse(text, id: repeats == 0 ? text : "\(text)#\(repeats)")
                entry.folded = ActivityPresenter.fold(text)
                entries.append(entry)
            }
        }
        return entries
    }

    /// Most disk the log takes: the rotated files together.
    public static var maxDiskBytes: Int { RotatingFileLog.fileSize * RotatingFileLog.fileCount }

    static func parse(_ line: String, id: String) -> LogEntry {
        let plain = LogEntry(id: id, date: nil, level: nil, category: "", message: line, raw: line)
        guard let space = line.firstIndex(of: " "),
              let date = Self.date(String(line[..<space])) else { return plain }
        let rest = line[line.index(after: space)...]
        guard rest.hasPrefix("["), let close = rest.firstIndex(of: "]"),
              let level = LogLevel(rawValue: rest[rest.index(after: rest.startIndex)..<close].lowercased()) else { return plain }
        let body = rest[rest.index(after: close)...].drop(while: { $0 == " " })
        guard let colon = body.range(of: ": ") else {
            return LogEntry(id: id, date: date, level: level, category: "", message: String(body), raw: line)
        }
        return LogEntry(id: id, date: date, level: level, category: String(body[..<colon.lowerBound]),
                        message: String(body[colon.upperBound...]), raw: line)
    }

    /// Lines written before timestamps had milliseconds have none.
    static func date(_ text: String) -> Date? {
        (try? Date(text, strategy: RotatingFileLog.timestampStyle)) ?? (try? Date(text, strategy: .iso8601))
    }

    /// Lines matching the level filter and a case/diacritic-insensitive search, still newest first.
    public static func filter(_ entries: [LogEntry], level: LogLevelFilter, query: String) -> [LogEntry] {
        let needle = ActivityPresenter.fold(query.trimmingCharacters(in: .whitespaces))
        return entries.filter { entry in
            level.matches(entry.level) && (needle.isEmpty || (entry.folded.isEmpty ? ActivityPresenter.fold(entry.raw) : entry.folded).contains(needle))
        }
    }

    /// The lines as they are in the file, oldest first, for the clipboard.
    public static func text(_ entries: [LogEntry]) -> String {
        entries.reversed().map(\.raw).joined(separator: "\n")
    }
}
