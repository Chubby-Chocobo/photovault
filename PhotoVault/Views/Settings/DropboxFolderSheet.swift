import PhotoVaultAppSupport
import PhotoVaultDropbox
import PhotoVaultCore
import SwiftUI

/// Folders of the signed-in Dropbox, one level at a time. The current folder is what gets imported.
@MainActor
@Observable
final class DropboxBrowserModel {
    enum Failure: Equatable {
        case signInRequired
        case other
    }

    /// Folders entered so far; empty at the root (the whole Dropbox).
    var trail: [DropboxFolder] = []
    var folders: [DropboxFolder] = []
    var loading = false
    var failure: Failure?
    var email: String?
    @ObservationIgnored var client: DropboxClient?

    var currentPath: String { trail.last?.path ?? "" }

    func load() async {
        guard let client else { return }
        loading = true
        failure = nil
        defer { loading = false }
        do {
            folders = try await client.listFolders(path: currentPath).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch SourceError.accessRevoked {
            folders = []
            failure = .signInRequired
        } catch {
            folders = []
            failure = .other
        }
    }

    func open(_ folder: DropboxFolder) async {
        trail.append(folder)
        await load()
    }

    /// `depth` 0 is the root; otherwise the first `depth` folders of the trail stay.
    func goTo(depth: Int) async {
        trail = Array(trail.prefix(depth))
        await load()
    }
}

struct DropboxFolderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var browser = DropboxBrowserModel()
    @State private var starting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr(vi: "Chọn thư mục Dropbox", en: "Choose a Dropbox folder")).font(.title3.weight(.semibold))
            breadcrumb
            list.frame(height: 220)
            HStack {
                Text(tr(vi: "Chỉ hiện thư mục. Ảnh trong cả thư mục con sẽ được nhập.", en: "Only folders are shown. Photos in subfolders are imported too."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr(vi: "Huỷ", en: "Cancel"), role: .cancel) { dismiss() }
                Button(tr(vi: "Nhập thư mục này", en: "Import this folder")) {
                    starting = true
                    Task {
                        if await model.importDropboxFolder(path: browser.currentPath, email: browser.email) { dismiss() }
                        starting = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(starting || browser.loading || browser.failure != nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            browser.client = model.dropboxBrowserClient()
            if let client = browser.client { browser.email = try? await client.currentAccountEmail() }
            await browser.load()
        }
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button(tr(vi: "Toàn bộ Dropbox", en: "All of Dropbox")) { Task { await browser.goTo(depth: 0) } }
                    .buttonStyle(.link).disabled(browser.trail.isEmpty)
                ForEach(Array(browser.trail.enumerated()), id: \.offset) { index, folder in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
                    Button(folder.name) { Task { await browser.goTo(depth: index + 1) } }
                        .buttonStyle(.link).disabled(index == browser.trail.count - 1)
                }
            }
        }
    }

    @ViewBuilder private var list: some View {
        if browser.loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let failure = browser.failure {
            VStack(spacing: 8) {
                Text(failure == .signInRequired
                    ? tr(vi: "Cần đăng nhập Dropbox lại.", en: "Sign in to Dropbox again.")
                    : tr(vi: "Không đọc được danh sách thư mục. Kiểm tra mạng rồi thử lại.", en: "Couldn’t load the folders. Check the network and try again."))
                Button(failure == .signInRequired ? tr(vi: "Đăng nhập lại", en: "Sign in again") : tr(vi: "Thử lại", en: "Try again")) {
                    Task {
                        if failure == .signInRequired {
                            guard await model.signInDropboxAgain() else { return }
                            browser.client = model.dropboxBrowserClient()
                            // The account may be another one; the import row shows this address.
                            browser.email = try? await browser.client?.currentAccountEmail()
                        }
                        await browser.load()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if browser.folders.isEmpty {
            Text(tr(vi: "Không có thư mục con.", en: "No subfolders.")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(browser.folders, id: \.path) { folder in
                Button { Task { await browser.open(folder) } } label: {
                    Label(folder.name, systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.bordered)
        }
    }
}
