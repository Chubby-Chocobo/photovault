import AppKit
import Foundation
import PhotoVaultDrive
import PhotoVaultLocal
import PhotoVaultAppSupport
import PhotoVaultCore

/// NSOpenPanel for NAS and external folders (FR-70) and the security-scoped bookmark of the pick.
@MainActor
enum FolderPicker {
    struct Pick {
        var url: URL
        var bookmark: Data
        var volumeName: String?
    }

    static func chooseFolder(message: String, prompt: String = tr(vi: "Chọn thư mục", en: "Choose")) -> Pick? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = prompt
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let bookmark = try? SecurityScopedBookmarkRoot.makeBookmark(for: url) else { return nil }
        let volume = try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName
        return Pick(url: url, bookmark: bookmark, volumeName: volume)
    }

    /// The folder was chosen but macOS would not give a bookmark for it, so it cannot be read later.
    struct BookmarkFailed: Error {}

    /// A folder to import from. It is only read: no "new folder" button, and the bookmark allows reading only.
    /// nil when the owner cancels; throws `BookmarkFailed` when the pick cannot be kept.
    static func chooseImportFolder() throws -> Pick? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = tr(vi: "Chọn thư mục ảnh để nhập một lần. PhotoVault chỉ đọc, không sửa hay xoá gì trong thư mục.", en: "Choose a folder of photos to import once. PhotoVault only reads it and never changes or deletes anything in it.")
        panel.prompt = tr(vi: "Nhập", en: "Import")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let bookmark = try? SecurityScopedBookmarkRoot.makeBookmark(for: url, readOnly: true) else { throw BookmarkFailed() }
        return Pick(url: url, bookmark: bookmark, volumeName: nil)
    }

    enum SyncedChoice {
        case picked(Pick)
        /// The owner pressed "Dùng trình duyệt thay thế" in the panel.
        case useBrowser
        case cancelled
    }

    /// Opens at the provider's synced folder on this Mac. Read-only like `chooseImportFolder`; the panel offers the
    /// browser sign-in as a second way when `offerBrowser`. Throws `BookmarkFailed` when the pick cannot be kept.
    static func chooseSyncedFolder(provider: SyncedCloudProvider, startAt: URL, offerBrowser: Bool) throws -> SyncedChoice {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = startAt
        panel.message = SyncedCloudText.panelTitle(provider)
        panel.prompt = tr(vi: "Nhập", en: "Import")
        let handler = BrowserInsteadHandler(panel: panel)
        // The browser flow needs the build's Google client id or Dropbox key; without them the button would only fail.
        if offerBrowser {
            let button = NSButton(title: SyncedCloudText.useBrowserInstead, target: handler, action: #selector(BrowserInsteadHandler.choose))
            button.bezelStyle = .rounded
            panel.accessoryView = button
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        if handler.chose { return .useBrowser }
        guard response == .OK, let url = panel.url else { return .cancelled }
        guard let bookmark = try? SecurityScopedBookmarkRoot.makeBookmark(for: url, readOnly: true) else { throw BookmarkFailed() }
        return .picked(Pick(url: url, bookmark: bookmark, volumeName: nil))
    }

    /// The folder a stored bookmark points to now (it may have been renamed since).
    /// Never mounts a share and never shows UI, but it can still block on a slow volume: call it off the main thread.
    nonisolated static func resolvedURL(bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: SecurityScopedBookmarkRoot.resolutionOptions, relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}

/// Target of the panel's "use the browser" button: closes the panel and remembers why.
@MainActor
private final class BrowserInsteadHandler: NSObject {
    private let panel: NSOpenPanel
    private(set) var chose = false

    init(panel: NSOpenPanel) { self.panel = panel }

    @objc func choose() {
        chose = true
        panel.cancel(nil)
    }
}
