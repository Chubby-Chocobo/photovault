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
            return StatusPresentation(label: "Đang hoạt động", code: code, tone: .green, needsOwnerDecision: false)
        case .paused(.userPaused):
            return StatusPresentation(label: "Tạm dừng (bởi bạn)", code: code, tone: .gray, needsOwnerDecision: false)
        case .paused(let reason):
            return StatusPresentation(
                label: "Tạm dừng · " + reasonText(reason), code: code, tone: .orange,
                needsOwnerDecision: [.rootTrashed, .rootMissing, .folderTrashed].contains(reason))
        case .unavailable(let reason):
            return StatusPresentation(label: "Không khả dụng · " + reasonText(reason), code: code, tone: .red, needsOwnerDecision: false)
        case .error(let reason):
            return StatusPresentation(label: "Lỗi · " + reasonText(reason), code: code, tone: .red, needsOwnerDecision: false)
        }
    }

    public static func reasonText(_ reason: StatusReason) -> String {
        switch reason {
        case .userPaused: "bởi bạn"
        case .full: "đích đã đầy"
        case .dailyCapReached: "đã đạt giới hạn upload trong ngày"
        case .offline: "mất kết nối"
        case .bookmarkInvalid: "mất quyền truy cập thư mục"
        case .reauthRequired: "cần đăng nhập lại"
        case .signedOut: "đã đăng xuất"
        case .rootMissing: "không thấy thư mục gốc"
        case .rootTrashed: "thư mục gốc trong Thùng rác"
        case .folderTrashed: "thư mục backup trong Thùng rác"
        case .recovering: "đang khôi phục trạng thái"
        }
    }

    /// Label of the backup mode shown next to a destination.
    public static func scopeText(_ scope: ScopeMode) -> String {
        switch scope {
        case .full: "Toàn bộ thư viện"
        case .since(let day): "Từ " + dayText(day)
        case .newOnly: "Chỉ ảnh mới"
        }
    }

    /// `2024-01-01` -> `01/01/2024`.
    public static func dayText(_ day: ArchiveDay) -> String {
        String(format: "%02d/%02d/%04d", day.day, day.month, day.year)
    }
}
