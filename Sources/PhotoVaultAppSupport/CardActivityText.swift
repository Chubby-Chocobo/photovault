import Foundation
import PhotoVaultCore
import PhotoVaultEngine

/// What a one-time job card says about the work behind its progress bar, so a long file never makes the
/// card look frozen. File names and e-mails appear on screen only.
public enum CardActivity: Equatable, Sendable {
    /// The file moving now, in the full form (`TransferLineText.Style.full`).
    case transfer(String)
    /// Nothing moves yet, but the next file is being got ready.
    case preparing(String)
    /// Nothing moves and a known reason holds the job back.
    case waiting(String)

    public var text: String {
        switch self {
        case .transfer(let text), .preparing(let text), .waiting(let text): text
        }
    }

    /// The card shows a small activity indicator.
    public var isBusy: Bool {
        if case .waiting = self { false } else { true }
    }
}

public enum CardActivityText {
    /// The backfill card: the longest-running file of a backfill job (whatever source it comes from), else why it
    /// waits, else "preparing".
    public static func backfill(snapshot: EngineSnapshot, transfers: [TransferProgress], now: Date, disk: MacDiskState, settings: GlobalSettings) -> CardActivity {
        if let line = TransferLineText.make(transfers.filter(\.isBackfill), now: now) { return .transfer(line) }
        return waiting(snapshot: snapshot, now: now, disk: disk, settings: settings)
            ?? .preparing(tr(vi: "Đang chuẩn bị file tiếp theo…", en: "Preparing the next file…"))
    }

    /// The import card: the transfer of this import's files (download from its source, upload of its files); nil when
    /// none is visible, so the card keeps its own status line.
    public static func importJob(_ id: SourceID, transfers: [TransferProgress], now: Date) -> String? {
        TransferLineText.make(transfers.filter { $0.sourceId == id }, now: now)
    }

    /// The transfers whose full line a card shows now: the Backfill card while it is shown, and the newest running
    /// import's card. The header keeps its short form only for these.
    public static func shownOnCards(snapshot: EngineSnapshot, transfers: [TransferProgress], now: Date) -> Set<UUID> {
        var ids = Set<UUID>()
        if PopoverJobVisibility.shows(backfill: snapshot), let main = TransferLineText.visible(transfers.filter(\.isBackfill), now: now).first {
            ids.insert(main.id)
        }
        if let newest = ImportProgressText.running(snapshot.imports).first,
           let main = TransferLineText.visible(transfers.filter { $0.sourceId == newest.id }, now: now).first {
            ids.insert(main.id)
        }
        return ids
    }

    private static func waiting(snapshot: EngineSnapshot, now: Date, disk: MacDiskState, settings: GlobalSettings) -> CardActivity? {
        switch snapshot.overall {
        case .paused: return .waiting(tr(vi: "Đã tạm dừng · bấm Tiếp tục tất cả", en: "Paused · click Resume all"))
        case .photosUnauthorized: return .waiting(tr(vi: "Chưa có quyền Photos", en: "No Photos access"))
        default: break
        }
        if disk != .ok {
            let resume = VietnameseFormat.gigabytes(MacDiskState.resumeBytes(settings: settings))
            return .waiting(tr(vi: "Ổ Mac gần đầy · backfill chờ trống từ \(resume)", en: "Mac disk almost full · backfill waits for \(resume) free"))
        }
        if snapshot.overall == .offline { return .waiting(tr(vi: "Chờ có mạng", en: "Waiting for the network")) }
        // A destination that is away only holds the backfill back when no other destination can make progress.
        let destinations = snapshot.destinations
        if !destinations.isEmpty, !destinations.contains(where: { $0.status == .active }),
           let away = destinations.first(where: { if case .unavailable = $0.status { true } else { false } }) {
            return .waiting(tr(vi: "\(away.displayName) chưa kết nối", en: "\(away.displayName) is not connected"))
        }
        if let due = snapshot.nextRetryAt {
            guard due > now else { return .preparing(tr(vi: "Đang thử lại…", en: "Retrying…")) }
            let left = TransferLineText.clock(seconds: due.timeIntervalSince(now))
            return .waiting(tr(vi: "Chờ thử lại sau \(left)", en: "Retrying in \(left)"))
        }
        return nil
    }
}
