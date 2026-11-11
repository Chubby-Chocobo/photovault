import Foundation
import PhotoVaultCore

/// Filter chips of the activity window (FR-63).
public enum ActivityFilter: String, CaseIterable, Identifiable, Sendable {
    case all, rename, move, missing, status, restore, progress

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: tr(vi: "Tất cả", en: "All")
        case .rename: tr(vi: "Đổi tên", en: "Rename")
        case .move: tr(vi: "Di chuyển", en: "Move")
        case .missing: tr(vi: "File thiếu", en: "Missing file")
        case .status: tr(vi: "Trạng thái", en: "Status")
        case .restore: tr(vi: "Khôi phục", en: "Restore")
        case .progress: tr(vi: "Tiến độ", en: "Progress")
        }
    }

    public func matches(_ kind: ActivityKind) -> Bool {
        switch self {
        case .all: true
        case .rename: kind == .renamed
        case .move: kind == .moved
        case .missing: kind == .missingFile
        case .status: kind == .statusChanged
        case .restore: kind == .recovered
        case .progress: kind == .milestone
        }
    }
}

public struct ActivityRow: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var time: String
    public var kind: ActivityKind
    public var kindLabel: String
    public var message: String
    public var destinationName: String?
}

public struct ActivityDayGroup: Identifiable, Equatable, Sendable {
    public var heading: String
    public var rows: [ActivityRow]
    public var id: String { heading }
}

public enum ActivityPresenter {
    public static func kindLabel(_ kind: ActivityKind) -> String {
        switch kind {
        case .renamed: tr(vi: "Đổi tên", en: "Rename")
        case .moved: tr(vi: "Di chuyển", en: "Move")
        case .missingFile: tr(vi: "File thiếu", en: "Missing file")
        case .statusChanged: tr(vi: "Trạng thái", en: "Status")
        case .recovered: tr(vi: "Khôi phục", en: "Restore")
        case .notice: tr(vi: "Thông báo", en: "Notice")
        case .milestone: tr(vi: "Tiến độ", en: "Progress")
        }
    }

    /// Lowercase without diacritics (`SearchFolding`).
    static func fold(_ text: String) -> String { SearchFolding.fold(text) }

    /// Newest-first events -> day groups, filtered by kind and a case/diacritic-insensitive search.
    public static func groups(
        _ events: [ActivityEvent], filter: ActivityFilter, query: String, destinationNames: [DestinationID: String],
        now: Date, calendar: Calendar = .current
    ) -> [ActivityDayGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var groups: [ActivityDayGroup] = []
        for (index, event) in events.enumerated() where filter.matches(event.kind) {
            let name = event.destinationId.flatMap { destinationNames[$0] }
            if !needle.isEmpty {
                let haystack = [event.message, name ?? "", kindLabel(event.kind)].joined(separator: " ")
                if !fold(haystack).contains(fold(needle)) { continue }
            }
            let row = ActivityRow(
                id: event.id ?? Int64(-index - 1), time: RelativeTimeText.time(event.at, calendar), kind: event.kind,
                kindLabel: kindLabel(event.kind), message: event.message, destinationName: name)
            let heading = RelativeTimeText.dayHeading(event.at, now: now, calendar: calendar)
            if let last = groups.indices.last, groups[last].heading == heading {
                groups[last].rows.append(row)
            } else {
                groups.append(ActivityDayGroup(heading: heading, rows: [row]))
            }
        }
        return groups
    }
}
