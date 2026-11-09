import Foundation
import PhotoVaultCore

/// Vietnamese notification texts. They never contain file names, album titles or paths (NFR-06).
public enum NotificationContent {
    public static func make(_ kind: NotificationKind, destinationName: String?, count: Int? = nil) -> (title: String, body: String) {
        let name = destinationName ?? tr(vi: "đích", en: "destination")
        let amount = count.map { VietnameseFormat.integer($0) } ?? ""
        let total = count ?? 0
        switch kind {
        case .photosPermissionLost:
            return (tr(vi: "PhotoVault mất quyền đọc Photos", en: "PhotoVault lost access to Photos"), tr(vi: "Bật lại trong System Settings › Privacy & Security › Photos. Backup dừng cho tới khi có quyền.", en: "Turn it back on in System Settings › Privacy & Security › Photos. Backup is stopped until access returns."))
        case .reauthRequired:
            return (tr(vi: "Cần đăng nhập Google lại", en: "Sign in to Google again"), tr(vi: "Phiên đăng nhập của \(name) đã hết hạn. Mở PhotoVault › Settings để đăng nhập lại.", en: "The sign-in for \(name) has expired. Open PhotoVault › Settings to sign in again."))
        case .destinationFull:
            return (tr(vi: "\(name) sắp đầy hoặc đã đầy", en: "\(name) is full or almost full"), tr(vi: "PhotoVault đã tạm dừng upload lên \(name). Giải phóng dung lượng rồi tiếp tục.", en: "PhotoVault paused uploads to \(name). Free up space, then resume."))
        case .folderTrashedOrMissing:
            return (tr(vi: "Thư mục backup trên \(name) bị xoá hoặc vào Thùng rác", en: "The backup folder on \(name) was deleted or moved to Trash"), tr(vi: "PhotoVault đã tạm dừng \(name) và chờ bạn quyết định. Mở menu bar để xem.", en: "PhotoVault paused \(name) and is waiting for your decision. Open the menu bar to review."))
        case .integrityMissing:
            return (
                tr(
                    vi: "Thiếu \(amount) file trên \(name)",
                    en: L10n.plural(total, one: "\(amount) file missing on \(name)", other: "\(amount) files missing on \(name)")),
                tr(vi: "Kiểm tra toàn vẹn không thấy các file PhotoVault đã ghi. Mở menu bar để quyết định có upload lại không.", en: "The integrity check can't find files PhotoVault wrote. Open the menu bar to decide whether to upload them again."))
        case .checksumMismatch:
            return (tr(vi: "Checksum lệch trên \(name)", en: "Checksum mismatch on \(name)"), tr(
                    vi: "\(amount) file ở đích không khớp checksum. Mở Hoạt động gần đây để xem chi tiết.",
                    en: L10n.plural(
                        total,
                        one: "\(amount) file at the destination has a checksum mismatch. Open Recent activity to see details.",
                        other: "\(amount) files at the destination have a checksum mismatch. Open Recent activity to see details.")))
        case .destinationOfflineLong:
            return (tr(vi: "\(name) offline quá 7 ngày", en: "\(name) has been offline for over 7 days"), tr(vi: "Kết nối lại ổ hoặc NAS để PhotoVault tiếp tục backup.", en: "Reconnect the drive or NAS so PhotoVault can continue backing up."))
        case .bookmarkInvalid:
            return (tr(vi: "Mất quyền truy cập thư mục của \(name)", en: "Lost access to the folder of \(name)"), tr(vi: "Mở Settings › Đích và chọn lại thư mục.", en: "Open Settings › Destinations and choose the folder again."))
        case .macDiskFullLong:
            return (tr(vi: "Ổ Mac đầy quá 24 giờ", en: "Mac disk full for over 24 hours"), tr(vi: "PhotoVault không export được ảnh mới. Giải phóng dung lượng hoặc hạ ngưỡng trong Settings › Nâng cao.", en: "PhotoVault can't export new photos. Free up space or lower the threshold in Settings › Advanced."))
        case .syncStalled:
            return (tr(vi: "Không sync được quá 24 giờ", en: "Sync has not worked for over 24 hours"), tr(vi: "Kiểm tra mạng, đăng nhập và các đích trong menu bar.", en: "Check the network, sign-in and the destinations in the menu bar."))
        }
    }
}
