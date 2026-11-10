import PhotoVaultCore
import SwiftUI

/// Shown before the browser opens: what Google's Picker will ask for and that it can read the chosen folders to their depth.
struct GoogleDriveExplainerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr(vi: "Nhập từ Google Drive", en: "Import from Google Drive")).font(.title3.weight(.semibold))
            Text(tr(
                vi: "PhotoVault sẽ mở trình duyệt để bạn chọn ảnh, video hoặc thư mục trên Google Drive. PhotoVault chỉ đọc những gì bạn chọn, không ghi hay xoá gì.",
                en: "PhotoVault opens your browser so you can choose photos, videos or folders on Google Drive. PhotoVault only reads what you choose and never writes or deletes anything."))
            Label {
                Text(tr(
                    vi: "Chọn một thư mục là đủ: PhotoVault đọc cả các thư mục con. Google sẽ hỏi quyền “xem và tải xuống mọi file trên Google Drive”; quyền này chỉ dùng để đọc thư mục bạn chọn. Khi nhập xong, PhotoVault xoá thông tin đăng nhập trên máy này; quyền vẫn còn trong tài khoản Google cho tới khi bạn gỡ tại myaccount.google.com/permissions.",
                    en: "Choosing a folder is enough: PhotoVault reads its subfolders too. Google will ask for permission to “see and download all your Google Drive files”; it is used only to read the folders you choose. When the import is done, PhotoVault deletes the sign-in on this Mac; the permission stays in your Google account until you remove it at myaccount.google.com/permissions."))
            } icon: {
                Image(systemName: "lightbulb")
            }
            .font(.callout)
            HStack {
                Spacer()
                Button(tr(vi: "Huỷ", en: "Cancel"), role: .cancel) { dismiss() }
                Button(tr(vi: "Mở trình duyệt", en: "Open browser")) {
                    dismiss()
                    model.importFromGoogleDrive()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
