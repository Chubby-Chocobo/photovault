import PhotoVaultCore
import SwiftUI

/// Shown before the browser opens: what Google's Picker will ask for and how to pick a folder's photos.
struct GoogleDriveExplainerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr(vi: "Nhập từ Google Drive", en: "Import from Google Drive")).font(.title3.weight(.semibold))
            Text(tr(
                vi: "PhotoVault sẽ mở trình duyệt để bạn chọn ảnh, video hoặc thư mục trên Google Drive. PhotoVault chỉ đọc những gì bạn chọn.",
                en: "PhotoVault opens your browser so you can choose photos, videos or folders on Google Drive. PhotoVault only reads what you choose."))
            Label {
                Text(tr(
                    vi: "Nếu chọn một thư mục, Google có thể không cho PhotoVault đọc ảnh bên trong. Hãy mở thư mục và chọn các ảnh trong đó (⌘A để chọn tất cả).",
                    en: "If you choose a folder, Google may not let PhotoVault read the photos inside. Open the folder and select the photos in it (⌘A selects all)."))
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
