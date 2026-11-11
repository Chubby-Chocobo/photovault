import Foundation
import PhotoVaultCore

/// The CSV the owner saves from the History window: UTF-8 with a byte-order mark (so spreadsheet apps read
/// Vietnamese names), CRLF line ends and RFC 4180 quoting. Column titles follow the interface language.
public enum HistoryCSV {
    public static let byteOrderMark = "\u{FEFF}"
    public static let lineEnd = "\r\n"

    /// A field with a comma, quote, CR or LF is quoted and its quotes doubled. A field that a spreadsheet would
    /// run as a formula (it starts with `=`, `+`, `-`, `@`, tab or CR) gets a leading `'`.
    public static func field(_ value: String) -> String {
        var text = value
        if let first = text.unicodeScalars.first, ["=", "+", "-", "@", "\t", "\r"].contains(first) { text = "'" + text }
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func line(_ fields: [String]) -> String { fields.map(field).joined(separator: ",") + lineEnd }

    /// Time with its UTC offset in the given zone: "2026-11-10T09:30:00+07:00".
    public static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: Transfers (Photos and Backfill tabs)

    public static var eventHeader: String {
        line([
            tr(vi: "Thời điểm", en: "Time"), tr(vi: "Gần đúng", en: "Approximate"), tr(vi: "File", en: "File"),
            tr(vi: "Đích", en: "Destination"), tr(vi: "Kết quả", en: "Result"), tr(vi: "Lý do upload", en: "Cause"),
            tr(vi: "Dung lượng (byte)", en: "Size (bytes)"), tr(vi: "Ngày chụp", en: "Taken"), tr(vi: "Lý do lỗi", en: "Reason"),
        ])
    }

    public static func eventLine(_ row: TransferEventRow, destinationNames: [DestinationID: String], timeZone: TimeZone) -> String {
        line([
            timestamp(row.at, timeZone: timeZone), row.approximate ? "≈" : "", row.fileName,
            HistoryText.destination(row.destinationId, names: destinationNames), HistoryText.outcome(row.outcome),
            HistoryText.origin(row.origin), String(row.bytes), row.capturedAt.map { timestamp($0, timeZone: timeZone) } ?? "",
            HistoryReasonText.upload(reason: row.reason, detail: row.detail) ?? "",
        ])
    }

    // MARK: Import tab

    public static var importHeader: String {
        line([
            tr(vi: "File", en: "File"), tr(vi: "Kết quả", en: "Result"), tr(vi: "Dung lượng (byte)", en: "Size (bytes)"),
            tr(vi: "Lý do", en: "Reason"), tr(vi: "Trùng với", en: "Duplicate of"),
        ])
    }

    public static func importLine(_ row: ImportItemRow) -> String {
        line([
            row.relativePath, HistoryText.importState(row.state), String(row.sizeBytes),
            HistoryReasonText.importItem(state: row.state, reason: row.reason) ?? "", row.duplicateOfName ?? "",
        ])
    }
}
