import Foundation

/// Vietnamese notification texts. They never contain file names, album titles or paths (NFR-06).
public enum NotificationContent {
    public static func make(_ kind: NotificationKind, destinationName: String?, count: Int? = nil) -> (title: String, body: String) {
        let name = destinationName ?? "đích"
        let amount = count.map { VietnameseFormat.integer($0) } ?? ""
        switch kind {
        case .photosPermissionLost:
            return ("PhotoVault mất quyền đọc Photos", "Bật lại trong System Settings › Privacy & Security › Photos. Backup dừng cho tới khi có quyền.")
        case .reauthRequired:
            return ("Cần đăng nhập Google lại", "Phiên đăng nhập của \(name) đã hết hạn. Mở PhotoVault › Settings để đăng nhập lại.")
        case .destinationFull:
            return ("\(name) sắp đầy hoặc đã đầy", "PhotoVault đã tạm dừng upload lên \(name). Giải phóng dung lượng rồi tiếp tục.")
        case .folderTrashedOrMissing:
            return ("Thư mục backup trên \(name) bị xoá hoặc vào Thùng rác", "PhotoVault đã tạm dừng \(name) và chờ bạn quyết định. Mở menu bar để xem.")
        case .integrityMissing:
            return ("Thiếu \(amount) file trên \(name)", "Kiểm tra toàn vẹn không thấy các file PhotoVault đã ghi. Mở menu bar để quyết định có upload lại không.")
        case .checksumMismatch:
            return ("Checksum lệch trên \(name)", "\(amount) file ở đích không khớp checksum. Mở Hoạt động gần đây để xem chi tiết.")
        case .destinationOfflineLong:
            return ("\(name) offline quá 7 ngày", "Kết nối lại ổ hoặc NAS để PhotoVault tiếp tục backup.")
        case .bookmarkInvalid:
            return ("Mất quyền truy cập thư mục của \(name)", "Mở Settings › Đích và chọn lại thư mục.")
        case .macDiskFullLong:
            return ("Ổ Mac đầy quá 24 giờ", "PhotoVault không export được ảnh mới. Giải phóng dung lượng hoặc hạ ngưỡng trong Settings › Nâng cao.")
        case .syncStalled:
            return ("Không sync được quá 24 giờ", "Kiểm tra mạng, đăng nhập và các đích trong menu bar.")
        }
    }
}
