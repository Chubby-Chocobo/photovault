import Foundation

/// Owner-facing words for a destination status (spec 8.9.2), shared by the status line and the
/// "Trạng thái" activity rows.
public enum DestinationStatusText {
    public static func label(_ status: DestinationStatus) -> String {
        switch status {
        case .active: tr(vi: "Đang hoạt động", en: "Active")
        case .paused(.userPaused): tr(vi: "Tạm dừng (bởi bạn)", en: "Paused (by you)")
        case .paused(let reason): tr(vi: "Tạm dừng · ", en: "Paused · ") + reasonText(reason)
        case .unavailable(let reason): tr(vi: "Không khả dụng · ", en: "Unavailable · ") + reasonText(reason)
        case .error(let reason): tr(vi: "Lỗi · ", en: "Error · ") + reasonText(reason)
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

    /// "Đang hoạt động → Tạm dừng · mất kết nối".
    public static func change(from old: DestinationStatus, to new: DestinationStatus) -> String {
        "\(label(old)) → \(label(new))"
    }
}
