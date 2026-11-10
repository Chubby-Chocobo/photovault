import Foundation
import PhotoVaultCore
import PhotoVaultEngine

/// Vietnamese messages for errors the owner can see. Details (paths, names) stay out; the log has the rest.
public enum ErrorText {
    public static func message(for error: any Error) -> String {
        if let error = error as? DestinationError { return message(for: error) }
        if let error = error as? DeviceGroupError {
            switch error {
            case .duplicateName: return tr(vi: "Đã có nhóm trùng tên. Hãy gộp hai nhóm thay vì đổi tên.", en: "A group with this name already exists. Merge the two groups instead of renaming.")
            case .emptyName: return tr(vi: "Tên nhóm không được để trống.", en: "The group name can't be empty.")
            case .unknownGroup: return tr(vi: "Không tìm thấy nhóm thiết bị này.", en: "This device group wasn't found.")
            }
        }
        if let error = error as? EngineError {
            switch error {
            case .notBaselined: return tr(vi: "PhotoVault chưa hoàn tất thiết lập ban đầu.", en: "PhotoVault hasn't finished its initial setup.")
            case .legacyLayout: return tr(
                vi: "Bản sao lưu này dùng bố cục thư mục cũ (0.1.0). Hãy bắt đầu lại trong Cài đặt › Nâng cao.",
                en: "This backup uses the old folder layout (0.1.0). Start over in Settings › Advanced.")
            case .alreadyRunning: return tr(vi: "PhotoVault đang chạy.", en: "PhotoVault is already running.")
            case .unsandboxedBuild: return tr(vi: "Bản không sandbox cần chạy với --dev-container.", en: "The non-sandboxed build must run with --dev-container.")
            case .invalidState: return tr(vi: "Trạng thái hiện tại không cho phép thao tác này.", en: "The current state doesn't allow this action.")
            }
        }
        if let error = error as? RootProblemError {
            switch error {
            case .notRootProblem: return tr(vi: "Đích này không còn lỗi thư mục gốc.", en: "This destination no longer has a root folder problem.")
            case .stillMissing: return tr(vi: "Vẫn chưa thấy thư mục gốc. Hãy khôi phục nó rồi thử lại.", en: "The root folder is still missing. Restore it and try again.")
            case .stillTrashed: return tr(vi: "Thư mục gốc vẫn đang ở Thùng rác.", en: "The root folder is still in Trash.")
            case .unsupported: return tr(vi: "Đích này không hỗ trợ thao tác này.", en: "This destination doesn't support this action.")
            }
        }
        return tr(vi: "Có lỗi xảy ra. Xem log để biết thêm chi tiết.", en: "Something went wrong. See the log for details.")
    }

    static func message(for error: DestinationError) -> String {
        switch error {
        case .unauthorized, .reauthRequired: tr(vi: "Cần đăng nhập Google lại.", en: "Sign in to Google again.")
        case .rateLimited: tr(vi: "Google đang giới hạn tốc độ. Thử lại sau ít phút.", en: "Google is limiting the request rate. Try again in a few minutes.")
        case .server: tr(vi: "Máy chủ đích trả lỗi. Thử lại sau.", en: "The destination server returned an error. Try again later.")
        case .offline: tr(vi: "Không kết nối được tới đích. Kiểm tra mạng hoặc ổ đã được mount chưa.", en: "Can't reach the destination. Check the network or whether the drive is mounted.")
        case .noSpace, .quotaExceeded: tr(vi: "Đích đã hết dung lượng.", en: "The destination is out of space.")
        case .dailyCapReached: tr(vi: "Đã đạt giới hạn upload trong ngày.", en: "Daily upload limit reached.")
        case .bookmarkInvalid: tr(vi: "Mất quyền truy cập thư mục. Hãy chọn lại thư mục.", en: "Lost access to the folder. Choose the folder again.")
        case .folderMissing, .rootMissing, .notFound: tr(vi: "Không tìm thấy thư mục ở đích.", en: "The folder wasn't found at the destination.")
        case .folderTrashed, .rootTrashed: tr(vi: "Thư mục ở đích đang nằm trong Thùng rác.", en: "The folder at the destination is in Trash.")
        case .foreignFile: tr(vi: "Thư mục này đang chứa dữ liệu không phải của PhotoVault.", en: "This folder contains data that doesn't belong to PhotoVault.")
        case .foreignModified: tr(vi: "Một file PhotoVault đã ghi bị sửa bởi chương trình khác.", en: "A file PhotoVault wrote was modified by another program.")
        case .checksumMismatch: tr(vi: "Checksum không khớp.", en: "Checksum mismatch.")
        case .viewsNotPermitted: tr(vi: "Quyền hiện tại không cho tạo shortcut nên các view đang tắt.", en: "The current permission doesn't allow creating shortcuts, so views are off.")
        case .alreadyExists, .sessionExpired: tr(vi: "Thao tác bị gián đoạn. Thử lại.", en: "The operation was interrupted. Try again.")
        case .itemRejected(let reason), .transient(let reason): reasonMessage(reason)
        }
    }

    /// Sign-in failures arrive as short English reasons; unknown reasons stay generic so nothing leaks.
    private static func reasonMessage(_ reason: String) -> String {
        if reason.contains("timed out") { return tr(vi: "Hết thời gian chờ đăng nhập. Thử lại.", en: "Sign-in timed out. Try again.") }
        if reason.contains("cancelled") { return tr(vi: "Đã huỷ đăng nhập.", en: "Sign-in was cancelled.") }
        if reason.contains("browser") { return tr(vi: "Không mở được trình duyệt mặc định.", en: "Couldn't open the default browser.") }
        if reason.contains("refresh token") { return tr(vi: "Google không cấp quyền duy trì đăng nhập. Hãy thử lại và chấp nhận mọi quyền được xin.", en: "Google didn't grant persistent sign-in. Try again and accept every permission requested.") }
        if reason.contains("drive.file scope not granted") {
            return tr(
                vi: "Google chưa cho phép PhotoVault ghi vào Google Drive. Thử lại và tích ô \"Xem, chỉnh sửa, tạo và xoá các tệp cụ thể trên Google Drive mà bạn dùng với ứng dụng này\".",
                en: "Google didn't allow PhotoVault to write to Google Drive. Try again and tick \"See, edit, create, and delete only the specific Google Drive files you use with this app\".")
        }
        if reason.hasPrefix("id token") {
            return tr(
                vi: "Google trả về thông tin tài khoản không dùng được. Kiểm tra ngày giờ của máy Mac rồi thử lại.",
                en: "Google returned account details that can't be used. Check the Mac's date and time, then try again.")
        }
        return tr(vi: "Lỗi tạm thời. Thử lại sau.", en: "Temporary error. Try again later.")
    }
}

/// The log line for a failed Google sign-in: the error's case and, for reasons the app writes itself,
/// that reason. Anything else is reduced to its type so no account detail or token reaches the log.
public enum SignInFailureLog {
    static let knownReasons: Set<String> = [
        "drive.file scope not granted", "refresh token missing", "token response malformed",
        "id token missing", "id token malformed", "id token audience", "id token issuer", "id token expired", "id token subject",
        "sign-in timed out", "sign-in cancelled", "browser could not be opened",
    ]

    public static func line(for error: any Error) -> String {
        guard let error = error as? DestinationError else { return "sign-in failed: \(type(of: error))" }
        switch error {
        case .itemRejected(let reason): return "sign-in failed: itemRejected(\(known(reason)))"
        case .transient(let reason): return "sign-in failed: transient(\(known(reason)))"
        case .server(let status): return "sign-in failed: server(\(status))"
        default: return "sign-in failed: \(caseName(error))"
        }
    }

    private static func known(_ reason: String) -> String { knownReasons.contains(reason) ? reason : "other" }

    private static func caseName(_ error: DestinationError) -> String {
        String(String(describing: error).prefix { $0 != "(" })
    }
}
