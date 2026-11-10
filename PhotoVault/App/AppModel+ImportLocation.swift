import AppKit
import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// Where an import came from: the folder a Mac import's bookmark points to now, and the Finder and web actions.
extension AppModel {
    /// The folder a Mac import's bookmark resolves to, or nil when it no longer does (disk unplugged, folder gone).
    /// Resolved off the main thread: a bookmark on a slow volume can block.
    func resolveImportFolder(_ id: SourceID) async -> URL? {
        guard let store = env?.store else { return nil }
        let bookmark = try? await store.read { db in try SourceRepository.fetch(db, id: id)?.config.bookmark }
        guard let bookmark else { return nil }
        return await Task.detached { FolderPicker.resolvedURL(bookmark: bookmark) }.value
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openOnWeb(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
