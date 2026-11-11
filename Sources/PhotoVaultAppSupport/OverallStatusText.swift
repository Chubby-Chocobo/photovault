import Foundation
import PhotoVaultCore
import PhotoVaultEngine

public enum OverallTone: String, Sendable, Equatable {
    case ok, orange, red
}

public struct OverallPresentation: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    /// The subtitle as the header lays it out on one line; a moving file keeps its extension when it is cut.
    public var subtitleLine: FittedLine
    public var tone: OverallTone
    /// The menu bar icon animates while the engine works.
    public var isWorking: Bool

    public init(title: String, subtitle: String, subtitleLine: FittedLine? = nil, tone: OverallTone, isWorking: Bool) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleLine = subtitleLine ?? FittedLine(lead: subtitle)
        self.tone = tone
        self.isWorking = isWorking
    }
}

/// The header of the menu bar popover (FR-60).
public enum OverallStatusText {
    public static func make(
        snapshot: EngineSnapshot, disk: MacDiskState, settings: GlobalSettings, now: Date, calendar: Calendar = .current,
        transfers: [TransferProgress] = []
    ) -> OverallPresentation {
        func result(_ title: String, _ subtitle: String, _ tone: OverallTone, working: Bool = false, line: FittedLine? = nil) -> OverallPresentation {
            OverallPresentation(title: title, subtitle: subtitle, subtitleLine: line, tone: tone, isWorking: working)
        }
        let destinations = snapshot.destinations
        switch snapshot.overall {
        case .legacyLayout:
            return result(
                tr(vi: "Cần bắt đầu lại", en: "A fresh start is needed"),
                tr(vi: "Bản sao lưu này dùng bố cục thư mục cũ (0.1.0)", en: "This backup uses the old folder layout (0.1.0)"), .red)
        case .paused:
            return result(
                tr(vi: "Đã tạm dừng tất cả", en: "All paused"),
                tr(vi: "Bấm Tiếp tục tất cả để chạy lại", en: "Click Resume all to run again"), .orange)
        case .photosUnauthorized:
            return result(
                tr(vi: "Chưa có quyền Photos", en: "No Photos access"),
                tr(vi: "Cấp quyền trong System Settings để tiếp tục", en: "Grant access in System Settings to continue"), .red)
        case .notBaselined:
            return result(
                tr(vi: "Chưa bắt đầu", en: "Not started"),
                tr(vi: "Hoàn tất thiết lập để bắt đầu backup", en: "Finish setup to start backing up"), .orange)
        default: break
        }
        let decisions = destinations.filter { StatusText.presentation(for: $0.status).needsOwnerDecision }
        if let first = decisions.first {
            return result(
                tr(vi: "Cần bạn quyết định", en: "Your decision is needed"),
                othersText(first.displayName, tr(vi: "đã tạm dừng", en: "paused"), destinations.count), .orange)
        }
        if disk == .critical {
            let resume = VietnameseFormat.gigabytes(MacDiskState.resumeBytes(settings: settings))
            return result(
                tr(vi: "Đã dừng export", en: "Export stopped"),
                tr(vi: "Ổ Mac gần đầy · chờ trống từ \(resume)", en: "Mac disk almost full · waiting for \(resume) free"), .red)
        }
        if let offline = destinations.first(where: { if case .unavailable = $0.status { true } else { false } }) {
            return result(offline.displayName + tr(vi: " không khả dụng", en: " unavailable"), othersText(offline.displayName, "", destinations.count, suffixOnly: true), .orange)
        }
        switch snapshot.overall {
        case .needsReconciliation:
            return result(
                tr(vi: "Cần đối soát thư viện", en: "Library reconciliation needed"),
                tr(vi: "Chạy Đối soát trong Settings › Nâng cao", en: "Run Reconcile in Settings › Advanced"), .orange)
        case .offline:
            return result(
                tr(vi: "Không có mạng", en: "No network"),
                tr(vi: "Tự chạy lại khi có mạng", en: "Resumes automatically when the network is back"), .orange)
        default: break
        }
        let last = destinations.compactMap(\.lastSuccessAt).max()
        let count = destinations.count
        let backfilling = snapshot.backfillTotalAssets > snapshot.backfillDoneAssets
        let importing = snapshot.imports.contains { $0.status == .scanning || $0.status == .importing }
        // A file that is moving replaces the summary, so a long transfer does not look like a hang. While a
        // card shows the full line (destination, account, bytes), the header keeps the short one.
        let headerMain = TransferLineText.visible(transfers, now: now).first
        let onCard = CardActivityText.shownOnCards(snapshot: snapshot, transfers: transfers, now: now)
        let style: TransferLineText.Style = headerMain.map { onCard.contains($0.id) } == true ? .short : .full
        let moving = TransferLineText.fitted(transfers, now: now, style: style)
        let tail = TransferLineText.make(transfers, now: now, style: style) ?? tr(
            vi: "\(count) đích · sync lần cuối ",
            en: L10n.plural(count, one: "1 destination · last sync ", other: "\(count) destinations · last sync ")) + RelativeTimeText.ago(last, now: now, calendar: calendar)
        if importing, !backfilling {
            return result(tr(vi: "Đang nhập ảnh", en: "Importing photos"), tail, .ok, working: snapshot.overall == .syncing, line: moving)
        }
        if snapshot.overall == .syncing || backfilling {
            return result(
                backfilling ? tr(vi: "Đang backfill", en: "Backfilling") : tr(vi: "Đang đồng bộ", en: "Syncing"), tail, .ok,
                working: snapshot.overall == .syncing, line: moving)
        }
        return result(tr(vi: "Đã đồng bộ", en: "Synced"), tail, .ok, line: moving)
    }

    private static func othersText(_ name: String, _ verb: String, _ total: Int, suffixOnly: Bool = false) -> String {
        let others = max(0, total - 1)
        let running = tr(
            vi: "\(others) đích khác vẫn chạy",
            en: L10n.plural(others, one: "1 other destination still running", other: "\(others) other destinations still running"))
        let tail = others > 0 ? " · " + running : ""
        if suffixOnly { return others > 0 ? running : tr(vi: "Chờ kết nối lại", en: "Waiting to reconnect") }
        return "\(name) \(verb)\(tail)"
    }
}
