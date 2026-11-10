import Foundation
import PhotoVaultCore
import PhotoVaultEngine

/// One line of the import queue: a running import first, then the ones waiting for the engine.
public struct ImportQueueRow: Equatable, Identifiable, Sendable {
    public var item: ImportSnapshot
    /// 1-based place in the list.
    public var number: Int
    public var isQueued: Bool
    /// Place among the waiting entries; nil for an import the engine already runs.
    public var place: Int?
    public var id: SourceID { item.id }

    /// "Đang chạy" or "Chờ · thứ N" (N counts the waiting ones only), in the language at the time of the call.
    public var badge: String {
        guard let place else { return tr(vi: "Đang chạy", en: "Running") }
        return tr(vi: "Chờ · thứ \(place)", en: "Waiting · \(ImportQueue.ordinal(place))")
    }
}

/// What the popover card shows: the first row with its progress and a short line about the rest.
public struct ImportQueuePopoverSummary: Equatable, Sendable {
    public var head: ImportQueueRow
    /// Other imports the engine already runs.
    public var runningCount: Int
    /// Entries that truly wait for the engine.
    public var waitingCount: Int
    /// Up to two names of the waiting entries.
    public var waitingNames: [String]

    /// "+1 đang chạy, +2 đang chờ: A, B…"; nil when nothing else is there.
    public var waitingLine: String? {
        var parts: [String] = []
        if runningCount > 0 { parts.append(tr(vi: "+\(runningCount) đang chạy", en: "+\(runningCount) running")) }
        if waitingCount > 0 {
            let names = waitingNames.joined(separator: ", ") + (waitingCount > waitingNames.count ? "…" : "")
            parts.append(tr(vi: "+\(waitingCount) đang chờ: \(names)", en: "+\(waitingCount) waiting: \(names)"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// Order, numbering, titles and icons of the import lists in Settings and the menu bar.
public enum ImportQueueLayout {
    public static var queueTitle: String { tr(vi: "Hàng đợi nhập", en: "Import queue") }
    public static var finishedTitle: String { tr(vi: "Đã nhập xong", en: "Finished imports") }
    public static var emptyText: String { tr(vi: "Không có lần nhập nào đang chạy hoặc chờ", en: "No imports are running or waiting") }

    /// Imports with work left: the ones the engine has recorded come first (they run now), then the waiting entries in the
    /// order they were added.
    public static func queueRows(_ imports: [ImportSnapshot]) -> [ImportQueueRow] {
        let open = ImportProgressText.running(imports)
        let recorded = open.filter { !ImportQueue.isQueued($0) }
        let waiting = open.filter(ImportQueue.isQueued)
        let ordered = recorded + waiting
        return ordered.enumerated().map { index, item in
            let queued = ImportQueue.isQueued(item)
            let place = queued ? (waiting.firstIndex { $0.id == item.id } ?? 0) + 1 : nil
            return ImportQueueRow(item: item, number: index + 1, isQueued: queued, place: place)
        }
    }

    /// Finished and cancelled imports, newest first.
    public static func finishedRows(_ imports: [ImportSnapshot]) -> [ImportSnapshot] {
        ImportProgressText.finished(imports).sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
    }

    public static func popoverSummary(_ rows: [ImportQueueRow]) -> ImportQueuePopoverSummary? {
        guard let head = rows.first else { return nil }
        let rest = rows.dropFirst()
        let waiting = rest.filter(\.isQueued)
        return ImportQueuePopoverSummary(
            head: head, runningCount: rest.count - waiting.count, waitingCount: waiting.count,
            waitingNames: waiting.prefix(2).map(\.item.displayName))
    }
}

/// SF Symbol of an import's provider; a synced folder differs from the same provider's web import.
public enum ImportProviderSymbol {
    public static func name(kind: SourceKind, synced: SyncedCloudProvider?) -> String {
        switch (kind, synced) {
        case (.localFolder, nil), (.photos, _): "folder"
        case (.localFolder, .googleDrive?): "externaldrive.badge.icloud"
        case (.localFolder, .dropbox?): "externaldrive.badge.checkmark"
        case (.googleDrive, _): "cloud"
        case (.dropbox, _): "shippingbox"
        }
    }
}
