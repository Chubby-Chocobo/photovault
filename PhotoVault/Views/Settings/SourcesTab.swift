import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultEngine
import SwiftUI

/// Settings › Nguồn: ongoing sources (Photos) and one-time imports.
struct SourcesTab: View {
    @Environment(AppModel.self) private var model
    @State private var photosCount: Int?
    @State private var confirmCancel: SourceID?
    @State private var showGoogleExplainer = false
    @State private var showDropboxBrowser = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ongoingSection
            importsSection
            SettingsNote(tr(
                vi: "Giữ thư mục và ổ đĩa chứa nó kết nối cho tới khi nhập xong. PhotoVault chỉ đọc, không sửa hay xoá gì trong thư mục.",
                en: "Keep the folder and the disk it is on connected until the import is done. PhotoVault only reads; it never changes or deletes anything in the folder."))
            SettingsNote(tr(
                vi: "Google Drive và Dropbox: PhotoVault chỉ đọc và tải ảnh về để sao lưu, không sửa hay xoá gì trên tài khoản của bạn.",
                en: "Google Drive and Dropbox: PhotoVault only reads and downloads photos to back them up; it never changes or deletes anything in your account."))
        }
        .sheet(isPresented: $showGoogleExplainer) { GoogleDriveExplainerSheet() }
        .sheet(isPresented: $showDropboxBrowser) { DropboxFolderSheet() }
        // Counted again with every snapshot, so the number follows the library while this tab is open.
        .task(id: model.snapshot?.updatedAt) { photosCount = await model.photosAssetCount() }
        .confirmationDialog(
            tr(vi: "Huỷ lần nhập này?", en: "Cancel this import?"), isPresented: Binding(get: { confirmCancel != nil }, set: { if !$0 { confirmCancel = nil } }),
            titleVisibility: .visible
        ) {
            Button(tr(vi: "Huỷ nhập", en: "Cancel import"), role: .destructive) {
                if let id = confirmCancel { model.cancelImport(id) }
                confirmCancel = nil
            }
            Button(tr(vi: "Tiếp tục nhập", en: "Keep importing"), role: .cancel) { confirmCancel = nil }
        } message: {
            Text(tr(
                vi: "File chưa upload sẽ không được upload nữa. File đã upload vẫn ở nguyên. Nhập lại thư mục này sau đó sẽ lấy lại phần còn thiếu.",
                en: "Files not yet uploaded will no longer be uploaded. Files already uploaded stay where they are. Importing the same folder again later picks up what is missing."))
        }
    }

    // MARK: Ongoing

    private var ongoingSection: some View {
        SettingsSection(tr(vi: "Nguồn liên tục", en: "Ongoing sources")) {
            HStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle").frame(width: 24).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Photos").font(.body.weight(.medium))
                    HStack(spacing: 5) {
                        StatusDot(color: photosTone)
                        Text(photosStatus).font(.caption)
                        if let photosCount {
                            Text("· " + tr(vi: "\(VietnameseFormat.integer(photosCount)) ảnh và video", en: "\(VietnameseFormat.integer(photosCount)) photos and videos"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            SettingsNote(tr(
                vi: "Liên tục: ảnh mới được sao lưu khi xuất hiện trong Photos.",
                en: "Ongoing: new photos are backed up as soon as they appear in Photos."))
        }
    }

    private var photosTone: Color {
        switch model.photosAuthorization {
        case .authorized: .green
        case .notDetermined: .secondary
        case .limited: .orange
        default: .red
        }
    }

    private var photosStatus: String {
        switch model.photosAuthorization {
        case .authorized: tr(vi: "Đang theo dõi", en: "Watching")
        case .notDetermined: tr(vi: "Chưa cấp quyền", en: "Not granted yet")
        case .limited: tr(vi: "Quyền giới hạn", en: "Limited access")
        default: tr(vi: "Chưa có quyền đọc Photos", en: "No Photos access")
        }
    }

    // MARK: Imports

    private var importsSection: some View {
        SettingsSection(tr(vi: "Nhập một lần", en: "One-time imports")) {
            HStack {
                Menu {
                    Button(tr(vi: "Từ thư mục trên Mac…", en: "From a folder on this Mac…")) { model.importFolder() }
                    Button(tr(vi: "Từ Google Drive…", en: "From Google Drive…")) { showGoogleExplainer = true }
                        .disabled(!model.googleImportAvailable || model.cloudFlowBusy)
                    Button(tr(vi: "Từ Dropbox…", en: "From Dropbox…")) {
                        Task { if await model.ensureDropboxSignedIn() { showDropboxBrowser = true } }
                    }
                    .disabled(!model.dropboxImportAvailable || model.cloudFlowBusy)
                    .help(model.dropboxImportAvailable ? "" : tr(
                        vi: "Bản này chưa có khoá ứng dụng Dropbox (DROPBOX_APP_KEY).",
                        en: "This build has no Dropbox app key (DROPBOX_APP_KEY)."))
                } label: {
                    Label(tr(vi: "Nhập ảnh…", en: "Import photos…"), systemImage: "square.and.arrow.down")
                }
                .menuStyle(.button)
                .fixedSize()
                .disabled(!model.canStartImport)
                if !model.canStartImport {
                    Text(tr(vi: "Hoàn tất thiết lập ban đầu trước.", en: "Finish the first setup first.")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if model.dropboxSignedIn {
                    Button(tr(vi: "Đăng xuất Dropbox", en: "Sign out of Dropbox")) { model.signOutDropbox() }
                        .controlSize(.small)
                        .help(tr(vi: "Các lần nhập đang có vẫn giữ quyền đọc riêng của chúng.", en: "Existing imports keep their own read access."))
                }
            }
            if !model.dropboxImportAvailable {
                Text(tr(vi: "Nhập từ Dropbox cần khoá ứng dụng Dropbox trong bản build này.", en: "Importing from Dropbox needs a Dropbox app key in this build."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            let running = model.runningImports
            if running.isEmpty && model.finishedImports.isEmpty {
                Text(tr(vi: "Chưa có lần nhập nào.", en: "No imports yet.")).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(running) { item in
                ImportRunningRow(item: item, waitingReason: ImportProgressText.waitingForPhotos(item, photosAllowsReading: model.photosAuthorization.allowsReading), onCancel: { confirmCancel = item.id }, onSignInAgain: { model.reconnectImport(item) })
            }
            let finished = model.finishedImports
            if !finished.isEmpty {
                Divider()
                Text(tr(vi: "Đã xong", en: "Finished")).font(.subheadline.weight(.semibold))
                ForEach(finished) { item in ImportFinishedRow(item: item, onSignInAgain: { model.reconnectImport(item) }) }
            }
        }
    }
}
