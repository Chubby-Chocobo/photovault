import Foundation
import PhotoVaultCore

/// The status line while files transfer: which file, where, and how far. File names appear in the
/// interface on this Mac only; nothing here is logged or persisted.
public enum TransferLineText {
    /// A transfer is shown only after it has run this long, so small files do not make the line flicker.
    public static let minimumVisibleSeconds: TimeInterval = 1
    static let nameLimit = 28
    static let destinationLimit = 24

    /// Transfers that have run long enough to show, longest-running first.
    public static func visible(_ transfers: [TransferProgress], now: Date) -> [TransferProgress] {
        transfers.enumerated()
            .filter { now.timeIntervalSince($0.element.startedAt) >= minimumVisibleSeconds }
            .sorted { ($0.element.startedAt, $0.offset) < ($1.element.startedAt, $1.offset) }
            .map(\.element)
    }

    /// The line for the transfer that has run longest, with a count of the others; nil when none is visible.
    public static func make(_ transfers: [TransferProgress], now: Date) -> String? {
        let shown = visible(transfers, now: now)
        guard let main = shown.first else { return nil }
        var parts = [action(for: main)]
        if let progress = sizes(done: main.bytesDone, total: main.bytesTotal) { parts.append(progress) }
        let others = shown.count - 1
        if others > 0 {
            parts.append(tr(vi: "+\(others) file khác", en: L10n.plural(others, one: "+1 more file", other: "+\(others) more files")))
        }
        return parts.joined(separator: " · ")
    }

    /// `1,2 / 2,6 GB (46%)`; only the bytes done when the total is unknown; nil before any byte moved.
    static func sizes(done: Int64, total: Int64?) -> String? {
        guard let total, total > 0 else { return done > 0 ? SizeText.bytes(done) : nil }
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

    private static func action(for transfer: TransferProgress) -> String {
        let name = middleTruncated(transfer.fileName, limit: nameLimit)
        let destination = transfer.destinationName.map { middleTruncated($0, limit: destinationLimit) }
        switch transfer.kind {
        case .exportFromPhotos:
            return tr(vi: "Đang xuất \(name) từ Photos", en: "Exporting \(name) from Photos")
        case .download(.dropbox):
            return tr(vi: "Đang tải \(name) từ Dropbox", en: "Downloading \(name) from Dropbox")
        case .download(.googleDrive):
            return tr(vi: "Đang tải \(name) từ Google Drive", en: "Downloading \(name) from Google Drive")
        case .download:
            return tr(vi: "Đang đọc \(name) từ thư mục Mac", en: "Reading \(name) from a Mac folder")
        case .upload:
            guard let destination else { return tr(vi: "Đang upload \(name)", en: "Uploading \(name)") }
            return tr(vi: "Đang upload \(name) lên \(destination)", en: "Uploading \(name) to \(destination)")
        case .copy:
            guard let destination else { return tr(vi: "Đang chép \(name)", en: "Copying \(name)") }
            return tr(vi: "Đang chép \(name) vào \(destination)", en: "Copying \(name) to \(destination)")
        }
    }
}
