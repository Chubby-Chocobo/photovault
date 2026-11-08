import AppKit
import Foundation
import PhotoVaultDrive
import PhotoVaultLocal

/// NSOpenPanel for NAS and external folders (FR-70) and the security-scoped bookmark of the pick.
@MainActor
enum FolderPicker {
    struct Pick {
        var url: URL
        var bookmark: Data
        var volumeName: String?
    }

    static func chooseFolder(message: String, prompt: String = "Chọn thư mục") -> Pick? {
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

    /// The folder a stored bookmark points to now (it may have been renamed since).
    static func resolvedURL(bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
