import Foundation
import PhotoVaultCore

/// Summaries of a backfill run or an import: when it ran, for how long, and the files and bytes of each result.
public enum HistoryRunText {
    /// "Thêm đích · NAS" / "Backfill thư viện".
    public static func title(_ run: BackfillRunRow, destinationNames: [DestinationID: String]) -> String {
        let cause = HistoryText.trigger(run.trigger)
        guard let destination = run.destinationId else { return cause }
        return cause + " · " + HistoryText.destination(destination, names: destinationNames)
    }

    /// "10/11/2026 09:00 → 10/11/2026 18:30 · 9 giờ 30 phút", or "… → đang chạy" while files wait.
    public static func period(start: Date, end: Date?, approximate: Bool = false, calendar: Calendar = .current) -> String {
        let from = HistoryText.time(start, approximate: approximate, calendar: calendar)
        guard let end else { return from + " → " + tr(vi: "đang chạy", en: "running") }
        return from + " → " + HistoryText.time(end, approximate: approximate, calendar: calendar) + " · " + duration(end.timeIntervalSince(start))
    }

    /// "45 giây", "12 phút", "3 giờ 5 phút", "2 ngày 4 giờ".
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let days = total / 86_400, hours = total % 86_400 / 3_600, minutes = total % 3_600 / 60
        if total < 60 { return tr(vi: "\(total) giây", en: L10n.plural(total, one: "1 second", other: "\(total) seconds")) }
        if total < 3_600 { return tr(vi: "\(minutes) phút", en: L10n.plural(minutes, one: "1 minute", other: "\(minutes) minutes")) }
        if total < 86_400 {
            let h = tr(vi: "\(hours) giờ", en: L10n.plural(hours, one: "1 hour", other: "\(hours) hours"))
            return minutes == 0 ? h : h + " " + tr(vi: "\(minutes) phút", en: L10n.plural(minutes, one: "1 minute", other: "\(minutes) minutes"))
        }
        let d = tr(vi: "\(days) ngày", en: L10n.plural(days, one: "1 day", other: "\(days) days"))
        return hours == 0 ? d : d + " " + tr(vi: "\(hours) giờ", en: L10n.plural(hours, one: "1 hour", other: "\(hours) hours"))
    }

    /// "Đã lên 1.200 file (3,0 GB) · Lỗi 3 file (12 MB)", in a fixed order, results without files left out.
    public static func totals(_ totals: [TransferOutcome: OutcomeTotal]) -> String {
        let parts = TransferOutcome.allCases.compactMap { outcome in
            totals[outcome].flatMap { $0.files > 0 ? HistoryText.outcome(outcome) + " " + files($0) : nil }
        }
        return parts.isEmpty ? tr(vi: "Chưa có file nào xong", en: "No file finished yet") : parts.joined(separator: " · ")
    }

    /// "Đã nhập 40 file (1,2 GB) · Đã có sẵn 3 file (80 MB)".
    public static func importTotals(_ totals: [ImportItemState: OutcomeTotal]) -> String {
        let order: [ImportItemState] = [.imported, .duplicate, .unsupported, .failed, .cancelled, .pending]
        let parts = order.compactMap { state in
            totals[state].flatMap { $0.files > 0 ? HistoryText.importState(state) + " " + files($0) : nil }
        }
        return parts.isEmpty ? tr(vi: "Chưa có file nào", en: "No files yet") : parts.joined(separator: " · ")
    }

    /// "12 file (3,0 GB)".
    static func files(_ total: OutcomeTotal) -> String {
        let count = L10n.integer(total.files)
        return tr(vi: "\(count) file", en: L10n.plural(total.files, one: "1 file", other: "\(count) files")) + " (" + SizeText.bytes(total.bytes) + ")"
    }
}
