import AppKit
import Foundation
import PhotoVaultDrive
import PhotoVaultLocal
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

    /// A folder to import from. It is only read: no "new folder" button, and the bookmark allows reading only.
    static func chooseImportFolder() -> Pick? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = tr(vi: "Chọn thư mục ảnh để nhập một lần. PhotoVault chỉ đọc, không sửa hay xoá gì trong thư mục.", en: "Choose a folder of photos to import once. PhotoVault only reads it and never changes or deletes anything in it.")
        panel.prompt = tr(vi: "Nhập", en: "Import")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let bookmark = try? SecurityScopedBookmarkRoot.makeBookmark(for: url, readOnly: true) else { return nil }
        return Pick(url: url, bookmark: bookmark, volumeName: nil)
    }

    /// The folder a stored bookmark points to now (it may have been renamed since).
    /// Never mounts a share and never shows UI, but it can still block on a slow volume: call it off the main thread.
    nonisolated static func resolvedURL(bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: SecurityScopedBookmarkRoot.resolutionOptions, relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
