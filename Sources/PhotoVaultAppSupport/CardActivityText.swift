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
    /// The backfill card: the longest-running Photos file, else why it waits, else "preparing".
    public static func backfill(snapshot: EngineSnapshot, transfers: [TransferProgress], now: Date, disk: MacDiskState, settings: GlobalSettings) -> CardActivity {
        let photos = transfers.filter { $0.sourceId == .photos }
        if let line = TransferLineText.make(photos, now: now) { return .transfer(line) }
        if let reason = waitingReason(snapshot: snapshot, now: now, disk: disk, settings: settings) { return .waiting(reason) }
        return .preparing(tr(vi: "Đang chuẩn bị file tiếp theo…", en: "Preparing the next file…"))
    }

    /// The import card: the transfer of this import's files (download from its source, upload of its files); nil when
    /// none is visible, so the card keeps its own status line.
    public static func importJob(_ id: SourceID, transfers: [TransferProgress], now: Date) -> String? {
        TransferLineText.make(transfers.filter { $0.sourceId == id }, now: now)
    }

    private static func waitingReason(snapshot: EngineSnapshot, now: Date, disk: MacDiskState, settings: GlobalSettings) -> String? {
        switch snapshot.overall {
        case .paused: return tr(vi: "Đã tạm dừng · bấm Tiếp tục tất cả", en: "Paused · click Resume all")
        case .photosUnauthorized: return tr(vi: "Chưa có quyền Photos", en: "No Photos access")
        default: break
        }
        if disk != .ok {
            let resume = VietnameseFormat.gigabytes(MacDiskState.resumeBytes(settings: settings))
            return tr(vi: "Ổ Mac gần đầy · backfill chờ trống từ \(resume)", en: "Mac disk almost full · backfill waits for \(resume) free")
        }
        if snapshot.overall == .offline { return tr(vi: "Chờ có mạng", en: "Waiting for the network") }
        if let away = snapshot.destinations.first(where: { if case .unavailable = $0.status { true } else { false } }) {
            return tr(vi: "\(away.displayName) không khả dụng · chờ kết nối lại", en: "\(away.displayName) unavailable · waiting to reconnect")
        }
        if let due = snapshot.nextRetryAt, due > now {
            let left = TransferLineText.clock(seconds: due.timeIntervalSince(now))
            return tr(vi: "Chờ thử lại sau \(left)", en: "Retrying in \(left)")
        }
        return nil
    }
}
