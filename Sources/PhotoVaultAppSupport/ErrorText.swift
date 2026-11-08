import Foundation
import PhotoVaultCore
import PhotoVaultEngine

/// Vietnamese messages for errors the owner can see. Details (paths, names) stay out; the log has the rest.
public enum ErrorText {
    public static func message(for error: any Error) -> String {
        if let error = error as? DestinationError { return message(for: error) }
        if let error = error as? DeviceGroupError {
            switch error {
            case .duplicateName: return "Đã có nhóm trùng tên. Hãy gộp hai nhóm thay vì đổi tên."
            case .emptyName: return "Tên nhóm không được để trống."
            case .unknownGroup: return "Không tìm thấy nhóm thiết bị này."
            }
        }
        if let error = error as? EngineError {
            switch error {
            case .notBaselined: return "PhotoVault chưa hoàn tất thiết lập ban đầu."
            case .alreadyRunning: return "PhotoVault đang chạy."
            case .unsandboxedBuild: return "Bản không sandbox cần chạy với --dev-container."
            case .invalidState: return "Trạng thái hiện tại không cho phép thao tác này."
            }
        }
        if let error = error as? RootProblemError {
            switch error {
            case .notRootProblem: return "Đích này không còn lỗi thư mục gốc."
            case .stillMissing: return "Vẫn chưa thấy thư mục gốc. Hãy khôi phục nó rồi thử lại."
            case .stillTrashed: return "Thư mục gốc vẫn đang ở Thùng rác."
            case .unsupported: return "Đích này không hỗ trợ thao tác này."
            }
        }
        return "Có lỗi xảy ra. Xem log để biết thêm chi tiết."
    }

    static func message(for error: DestinationError) -> String {
        switch error {
        case .unauthorized, .reauthRequired: "Cần đăng nhập Google lại."
        case .rateLimited: "Google đang giới hạn tốc độ. Thử lại sau ít phút."
        case .server: "Máy chủ đích trả lỗi. Thử lại sau."
        case .offline: "Không kết nối được tới đích. Kiểm tra mạng hoặc ổ đã được mount chưa."
        case .noSpace, .quotaExceeded: "Đích đã hết dung lượng."
        case .dailyCapReached: "Đã đạt giới hạn upload trong ngày."
        case .bookmarkInvalid: "Mất quyền truy cập thư mục. Hãy chọn lại thư mục."
        case .folderMissing, .rootMissing, .notFound: "Không tìm thấy thư mục ở đích."
        case .folderTrashed, .rootTrashed: "Thư mục ở đích đang nằm trong Thùng rác."
        case .foreignFile: "Thư mục này đang chứa dữ liệu không phải của PhotoVault."
        case .foreignModified: "Một file PhotoVault đã ghi bị sửa bởi chương trình khác."
        case .checksumMismatch: "Checksum không khớp."
        case .viewsNotPermitted: "Quyền hiện tại không cho tạo shortcut nên các view đang tắt."
        case .alreadyExists, .sessionExpired: "Thao tác bị gián đoạn. Thử lại."
        case .itemRejected(let reason), .transient(let reason): reasonMessage(reason)
        }
    }

    /// Sign-in failures arrive as short English reasons; unknown reasons stay generic so nothing leaks.
    private static func reasonMessage(_ reason: String) -> String {
        if reason.contains("timed out") { return "Hết thời gian chờ đăng nhập. Thử lại." }
        if reason.contains("cancelled") { return "Đã huỷ đăng nhập." }
        if reason.contains("browser") { return "Không mở được trình duyệt mặc định." }
        if reason.contains("refresh token") { return "Google không cấp quyền duy trì đăng nhập. Hãy thử lại và chấp nhận mọi quyền được xin." }
        return "Lỗi tạm thời. Thử lại sau."
    }
}
