import Foundation
import PhotoVaultCore
import PhotoVaultEngine

public enum OverallTone: String, Sendable, Equatable {
    case ok, orange, red
}

public struct OverallPresentation: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var tone: OverallTone
    /// The menu bar icon animates while the engine works.
    public var isWorking: Bool

    public init(title: String, subtitle: String, tone: OverallTone, isWorking: Bool) {
        self.title = title
        self.subtitle = subtitle
        self.tone = tone
        self.isWorking = isWorking
    }
}

/// The header of the menu bar popover (FR-60).
public enum OverallStatusText {
    public static func make(
        snapshot: EngineSnapshot, disk: MacDiskState, settings: GlobalSettings, now: Date, calendar: Calendar = .current
    ) -> OverallPresentation {
        func result(_ title: String, _ subtitle: String, _ tone: OverallTone, working: Bool = false) -> OverallPresentation {
            OverallPresentation(title: title, subtitle: subtitle, tone: tone, isWorking: working)
        }
        let destinations = snapshot.destinations
        switch snapshot.overall {
        case .paused:
            return result("Đã tạm dừng tất cả", "Bấm Tiếp tục tất cả để chạy lại", .orange)
        case .photosUnauthorized:
            return result("Chưa có quyền Photos", "Cấp quyền trong System Settings để tiếp tục", .red)
        case .notBaselined:
            return result("Chưa bắt đầu", "Hoàn tất thiết lập để bắt đầu backup", .orange)
        default: break
        }
        let decisions = destinations.filter { StatusText.presentation(for: $0.status).needsOwnerDecision }
        if let first = decisions.first {
            return result("Cần bạn quyết định", othersText(first.displayName, "đã tạm dừng", destinations.count), .orange)
        }
        if disk == .critical {
            let resume = VietnameseFormat.gigabytes(MacDiskState.resumeBytes(settings: settings))
            return result("Đã dừng export", "Ổ Mac gần đầy · chờ trống từ \(resume)", .red)
        }
        if let offline = destinations.first(where: { if case .unavailable = $0.status { true } else { false } }) {
            return result(offline.displayName + " không khả dụng", othersText(offline.displayName, "", destinations.count, suffixOnly: true), .orange)
        }
        switch snapshot.overall {
        case .needsReconciliation:
            return result("Cần đối soát thư viện", "Chạy Đối soát trong Settings › Nâng cao", .orange)
        case .offline:
            return result("Không có mạng", "Tự chạy lại khi có mạng", .orange)
        default: break
        }
        let last = destinations.compactMap(\.lastSuccessAt).max()
        let tail = "\(destinations.count) đích · sync lần cuối " + RelativeTimeText.ago(last, now: now, calendar: calendar)
        let backfilling = snapshot.backfillTotalAssets > snapshot.backfillDoneAssets
        if snapshot.overall == .syncing || backfilling {
            return result(backfilling ? "Đang backfill" : "Đang đồng bộ", tail, .ok, working: snapshot.overall == .syncing)
        }
        return result("Đã đồng bộ", tail, .ok)
    }

    private static func othersText(_ name: String, _ verb: String, _ total: Int, suffixOnly: Bool = false) -> String {
        let others = max(0, total - 1)
        let tail = others > 0 ? " · \(others) đích khác vẫn chạy" : ""
        if suffixOnly { return others > 0 ? "\(others) đích khác vẫn chạy" : "Chờ kết nối lại" }
        return "\(name) \(verb)\(tail)"
    }
}
