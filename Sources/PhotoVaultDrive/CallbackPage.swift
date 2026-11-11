/// The page the browser shows once the app knows how the OAuth redirect ended. Every page is static text, Vietnamese
/// then English: nothing from the request or from the error is put into it.
public enum CallbackPage: Sendable, CaseIterable {
    case success
    /// Consent was given with the box that lets PhotoVault use its own Drive files cleared.
    case driveScopeMissing
    /// Google gave no refresh token, so the sign-in would not last.
    case persistentSignInMissing
    /// Any other failure, and the page sent when nobody answers in time.
    case failed
    /// The Picker selection was too long for the redirect to carry.
    case selectionTooLarge

    var status: String { self == .success ? "200 OK" : "400 Bad Request" }

    var html: String {
        switch self {
        case .success:
            Self.page("Đã xong. Bạn có thể đóng tab này và quay lại PhotoVault.",
                      "Done. You can close this tab and return to PhotoVault.")
        case .driveScopeMissing:
            Self.page(
                "Đăng nhập không thành công: Google chưa cho phép PhotoVault ghi vào Google Drive. Hãy đóng tab này, "
                    + "đăng nhập lại trong PhotoVault và tích ô “Xem, chỉnh sửa, tạo và xoá các tệp cụ thể trên Google Drive "
                    + "mà bạn dùng với ứng dụng này”.",
                "Quyền này chỉ cho PhotoVault dùng các tệp do PhotoVault tạo.",
                "Sign-in failed: Google didn't allow PhotoVault to write to Google Drive. Close this tab, sign in again "
                    + "from PhotoVault, and tick “See, edit, create, and delete only the specific Google Drive files you use "
                    + "with this app”.",
                "This only lets PhotoVault use the files it creates.")
        case .persistentSignInMissing:
            Self.page(
                "Đăng nhập không thành công: Google không cấp quyền duy trì đăng nhập. Hãy đóng tab này, thử lại trong "
                    + "PhotoVault và chấp nhận mọi quyền được xin.",
                "Sign-in failed: Google didn't grant persistent sign-in. Close this tab, try again in PhotoVault, and "
                    + "accept every permission requested.")
        case .failed:
            Self.page("Đăng nhập không thành công. Hãy đóng tab này và thử lại trong PhotoVault.",
                      "Sign-in failed. Close this tab and try again in PhotoVault.")
        case .selectionTooLarge:
            Self.page("Bạn đã chọn quá nhiều mục cùng lúc. Hãy đóng tab này và chọn ít hơn trong PhotoVault.",
                      "Too many items were selected at once. Close this tab and pick fewer in PhotoVault.")
        }
    }

    private static func page(_ paragraphs: String...) -> String {
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>PhotoVault</title></head><body>"
            + paragraphs.map { "<p>\($0)</p>" }.joined() + "</body></html>"
    }
}
