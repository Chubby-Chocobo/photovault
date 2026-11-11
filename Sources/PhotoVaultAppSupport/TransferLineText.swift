import Foundation
import PhotoVaultCore

/// The status line while files transfer: which file, where, and how far. File names appear in the
/// interface on this Mac only; nothing here is logged or persisted.
public enum TransferLineText {
    /// A transfer is shown only after it has run this long, so small files do not make the line flicker.
    public static let minimumVisibleSeconds: TimeInterval = 1
    /// Elapsed time joins the line after this long, so a slow chunk still shows movement every second.
    static let elapsedAfterSeconds: TimeInterval = 10
    static let nameLimit = 28
    static let destinationLimit = 24
    static let accountLimit = 28

    /// Transfers that have run long enough to show, longest-running first.
    public static func visible(_ transfers: [TransferProgress], now: Date) -> [TransferProgress] {
        transfers.enumerated()
            .filter { now.timeIntervalSince($0.element.startedAt) >= minimumVisibleSeconds }
            .sorted { ($0.element.startedAt, $0.offset) < ($1.element.startedAt, $1.offset) }
            .map(\.element)
    }

    /// `full` names the destination, account, bytes and elapsed time (the cards and the tooltip). `short` is the
    /// file, its action and a percentage, for the header while a card already shows the full line.
    public enum Style: Sendable { case full, short }

    /// The line for the transfer that has run longest, with a count of the others; nil when none is visible.
    public static func make(_ transfers: [TransferProgress], now: Date, style: Style = .full) -> String? {
        fitted(transfers, now: now, style: style)?.text
    }

    /// The same line split for one fixed-height line: the action up to the file name, where it goes, and the
    /// numbers with the count of the others.
    public static func fitted(_ transfers: [TransferProgress], now: Date, style: Style = .full) -> FittedLine? {
        let shown = visible(transfers, now: now)
        guard let main = shown.first else { return nil }
        let (lead, place) = action(for: main, style: style)
        var parts: [String] = []
        if style == .short {
            if let fraction = main.fraction, main.bytesDone > 0 { parts.append("\(Int(fraction * 100))%") }
        } else {
            if let progress = sizes(done: main.bytesDone, total: main.bytesTotal) { parts.append(progress) }
            let elapsed = now.timeIntervalSince(main.startedAt)
            if elapsed >= elapsedAfterSeconds { parts.append(clock(seconds: elapsed)) }
        }
        let others = shown.count - 1
        if others > 0 {
            parts.append(tr(vi: "+\(others) file khác", en: L10n.plural(others, one: "+1 more file", other: "+\(others) more files")))
        }
        return FittedLine(lead: lead, place: place, detail: parts.map { " · " + $0 }.joined())
    }

    /// `2:05`, or `1:02:05` past an hour.
    static func clock(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    /// `1,2 / 2,6 GB (46%)`; only the bytes done when the total is unknown; nil before any byte moved.
    static func sizes(done: Int64, total: Int64?) -> String? {
        guard done > 0 else { return nil }
        guard let total, total > 0 else { return SizeText.bytes(done) }
        let done = min(max(done, 0), total)
        var left = SizeText.bytes(done)
        let right = SizeText.bytes(total)
        if let leftUnit = left.split(separator: " ").last, leftUnit == right.split(separator: " ").last, left.contains(" ") {
            left = String(left.dropLast(leftUnit.count + 1))
        }
        let percent = Int(Double(done) / Double(total) * 100)
        return "\(left) / \(right) (\(percent)%)"
    }

    /// Shortens `name` to `limit` characters by replacing the middle with `…`; the end (the extension) stays.
    public static func middleTruncated(_ name: String, limit: Int) -> String {
        let characters = Array(name)
        guard limit > 0, characters.count > limit else { return name }
        guard limit > 1 else { return "…" }
        let tail = max(1, limit / 3)
        let head = limit - 1 - tail
        return String(characters.prefix(head)) + "…" + String(characters.suffix(tail))
    }

    /// Stands for the file name while the sentence is put together, so the sentence can be cut right after the name
    /// whatever the language's word order. A private-use character never appears in the fixed words.
    private static let nameMarker = "\u{E000}"

    /// The sentence up to and including the file name, and the rest of it.
    private static func action(for transfer: TransferProgress, style: Style) -> (lead: String, place: String) {
        let name = middleTruncated(transfer.fileName, limit: nameLimit)
        let sentence = sentence(for: transfer, name: nameMarker, style: style)
        guard let marker = sentence.range(of: nameMarker) else { return (sentence, "") }
        return (String(sentence[..<marker.lowerBound]) + name, String(sentence[marker.upperBound...]))
    }

    private static func sentence(for transfer: TransferProgress, name: String, style: Style) -> String {
        let full = style == .full
        let destination = full ? transfer.destinationName.map { middleTruncated($0, limit: destinationLimit) } : nil
        let account = full ? transfer.accountEmail.map { " (\(middleTruncated($0, limit: accountLimit)))" } ?? "" : ""
        switch transfer.kind {
        case .exportFromPhotos where transfer.bytesDone == 0:
            // Photos sends no bytes while it fetches an iCloud-only original; they arrive once it is on this Mac.
            return tr(vi: "Đang tải \(name) từ iCloud", en: "Downloading \(name) from iCloud")
        case .exportFromPhotos:
            return tr(vi: "Đang xuất \(name) từ Photos", en: "Exporting \(name) from Photos")
        case .download(.dropbox):
            return tr(vi: "Đang tải \(name) từ Dropbox\(account)", en: "Downloading \(name) from Dropbox\(account)")
        case .download(.googleDrive):
            return tr(vi: "Đang tải \(name) từ Google Drive\(account)", en: "Downloading \(name) from Google Drive\(account)")
        case .download:
            return tr(vi: "Đang đọc \(name) từ thư mục Mac", en: "Reading \(name) from a Mac folder")
        case .upload:
            guard let destination else { return tr(vi: "Đang upload \(name)", en: "Uploading \(name)") }
            return tr(vi: "Đang upload \(name) lên \(destination)\(account)", en: "Uploading \(name) to \(destination)\(account)")
        case .copy:
            guard let destination else { return tr(vi: "Đang chép \(name)", en: "Copying \(name)") }
            return tr(vi: "Đang chép \(name) vào \(destination)", en: "Copying \(name) to \(destination)")
        }
    }
}
