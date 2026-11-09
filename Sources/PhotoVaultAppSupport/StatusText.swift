import Foundation
import PhotoVaultCore

public enum StatusTone: String, Sendable, Equatable {
    case green, orange, red, gray
}

public struct StatusPresentation: Equatable, Sendable {
    public var label: String
    /// Raw enum 8.9.2 text for tooltips and logs, e.g. `paused(rootTrashed)`.
    public var code: String
    public var tone: StatusTone
    /// The owner has to decide something (FR-47); the UI shows the prompt card.
    public var needsOwnerDecision: Bool
}

/// Vietnamese text for destination status (spec 8.9.2) and the Mac disk guard.
public enum StatusText {
    public static func presentation(for status: DestinationStatus) -> StatusPresentation {
        let code = status.description
        switch status {
        case .active:
            return StatusPresentation(label: tr(vi: "Đang hoạt động", en: "Active"), code: code, tone: .green, needsOwnerDecision: false)
        case .paused(.userPaused):
            return StatusPresentation(label: tr(vi: "Tạm dừng (bởi bạn)", en: "Paused (by you)"), code: code, tone: .gray, needsOwnerDecision: false)
        case .paused(let reason):
            return StatusPresentation(
                label: tr(vi: "Tạm dừng · ", en: "Paused · ") + reasonText(reason), code: code, tone: .orange,
                needsOwnerDecision: [.rootTrashed, .rootMissing, .folderTrashed].contains(reason))
        case .unavailable(let reason):
            return StatusPresentation(label: tr(vi: "Không khả dụng · ", en: "Unavailable · ") + reasonText(reason), code: code, tone: .red, needsOwnerDecision: false)
        case .error(let reason):
            return StatusPresentation(label: tr(vi: "Lỗi · ", en: "Error · ") + reasonText(reason), code: code, tone: .red, needsOwnerDecision: false)
        }
    }

    public static func reasonText(_ reason: StatusReason) -> String {
        switch reason {
        case .userPaused: tr(vi: "bởi bạn", en: "by you")
        case .full: tr(vi: "đích đã đầy", en: "destination is full")
        case .dailyCapReached: tr(vi: "đã đạt giới hạn upload trong ngày", en: "daily upload limit reached")
        case .offline: tr(vi: "mất kết nối", en: "offline")
        case .bookmarkInvalid: tr(vi: "mất quyền truy cập thư mục", en: "lost access to the folder")
        case .reauthRequired: tr(vi: "cần đăng nhập lại", en: "sign-in required")
        case .signedOut: tr(vi: "đã đăng xuất", en: "signed out")
        case .rootMissing: tr(vi: "không thấy thư mục gốc", en: "root folder not found")
        case .rootTrashed: tr(vi: "thư mục gốc trong Thùng rác", en: "root folder is in Trash")
        case .folderTrashed: tr(vi: "thư mục backup trong Thùng rác", en: "backup folder is in Trash")
        case .recovering: tr(vi: "đang khôi phục trạng thái", en: "recovering state")
        }
    }

    /// Label of the backup mode shown next to a destination.
    public static func scopeText(_ scope: ScopeMode) -> String {
        switch scope {
        case .full: tr(vi: "Toàn bộ thư viện", en: "Entire library")
        case .since(let day): tr(vi: "Từ ", en: "From ") + dayText(day)
        case .newOnly: tr(vi: "Chỉ ảnh mới", en: "New photos only")
        }
    }

    /// `2024-01-01` -> `01/01/2024`.
    public static func dayText(_ day: ArchiveDay) -> String {
        String(format: "%02d/%02d/%04d", day.day, day.month, day.year)
    }
}
