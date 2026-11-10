import AppKit
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
            queueSection
            finishedSection
            SettingsNote(tr(
                vi: "Giữ thư mục và ổ đĩa chứa nó kết nối cho tới khi nhập xong. PhotoVault chỉ đọc, không sửa hay xoá gì trong thư mục.",
                en: "Keep the folder and the disk it is on connected until the import is done. PhotoVault only reads; it never changes or deletes anything in the folder."))
            SettingsNote(tr(
                vi: "Google Drive và Dropbox: PhotoVault chỉ đọc và tải ảnh về để sao lưu, không sửa hay xoá gì trên tài khoản của bạn.",
                en: "Google Drive and Dropbox: PhotoVault only reads and downloads photos to back them up; it never changes or deletes anything in your account."))
        }
        .onAppear { model.refreshSyncedFolders() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshSyncedFolders() }
        .sheet(isPresented: $showGoogleExplainer) { GoogleDriveExplainerSheet() }
        .sheet(isPresented: $showDropboxBrowser) { DropboxFolderSheet() }
        // Counted again with every snapshot, so the number follows the library while this tab is open.
        .task(id: model.snapshot?.updatedAt) { photosCount = await model.photosAssetCount() }
        .task(id: "\(model.dropboxSignedIn)-\(model.cloudFlowBusy)") { await model.refreshDropboxEmail() }
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

    /// The menu items for one provider: the synced folder on this Mac and/or the browser sign-in.
    @ViewBuilder
    private func providerItems(_ provider: SyncedCloudProvider, browserConfigured: Bool, openBrowser: @escaping () -> Void) -> some View {
        ForEach(ImportMenuChoices.items(
            provider, appPresent: model.syncedAvailable(provider), browserConfigured: browserConfigured,
            dropbox: provider == .dropbox ? (model.dropboxSignedIn ? .signedIn(email: model.dropboxEmail) : .signedOut) : .notApplicable), id: \.title) { item in
            Button(item.title) {
                switch item.action {
                case .syncedFolder: model.importFromSyncedFolder(provider)
                case .browser: openBrowser()
                case .signOut: model.signOutDropbox()
                }
            }
            .disabled(!item.isEnabled || (item.action != .syncedFolder && item.action != .signOut && model.cloudFlowBusy))
            .help(item.help)
        }
    }

    private func openDropboxBrowser() {
        Task { if await model.ensureDropboxSignedIn() { showDropboxBrowser = true } }
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
                    if let line = model.snapshot.flatMap({ BackfillText.settingsLine($0) }) {
                        Text(line).font(.caption).foregroundStyle(.secondary)
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
                    providerItems(.googleDrive, browserConfigured: model.googleImportAvailable) { showGoogleExplainer = true }
                    providerItems(.dropbox, browserConfigured: model.dropboxImportAvailable) { openDropboxBrowser() }
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
            }
            if model.cloudFlowBusy { BrowserWaitRow(stage: model.cloudFlowStage, onCancel: model.cancelCloudFlow) }
        }
    }

    /// Running and waiting imports as a numbered list, apart from the "Nhập một lần" actions.
    private var queueSection: some View {
        let rows = model.queueRows
        return SettingsSection(ImportQueueLayout.queueTitle) {
            if rows.isEmpty {
                Text(ImportQueueLayout.emptyText).font(.callout).foregroundStyle(.secondary)
            } else {
                ImportListBox {
                    ForEach(rows) { row in
                        ImportListRow(first: row.number == 1) {
                            ImportRunningRow(
                                row: row,
                                waitingReason: ImportProgressText.waitingForPhotos(row.item, photosAllowsReading: model.photosAuthorization.allowsReading),
                                signedInWaiting: model.resumingImports.contains(row.id), cancelling: model.cancellingImports.contains(row.id),
                                queueWait: model.queueWait(for: row.item), waitReason: model.engineWaitReason,
                                onCancel: { confirmCancel = row.id }, onSignInAgain: { model.reconnectImport(row.item) })
                        }
                    }
                }
            }
        }
    }

    /// Finished and cancelled imports, newest first.
    @ViewBuilder private var finishedSection: some View {
        let finished = model.finishedImports
        if !finished.isEmpty {
            SettingsSection(ImportQueueLayout.finishedTitle) {
                ImportListBox {
                    ForEach(Array(finished.enumerated()), id: \.element.id) { index, item in
                        ImportListRow(first: index == 0) {
                            ImportFinishedRow(item: item, signedInWaiting: model.resumingImports.contains(item.id), waitReason: model.engineWaitReason, onSignInAgain: { model.reconnectImport(item) })
                        }
                    }
                }
            }
        }
    }
}
