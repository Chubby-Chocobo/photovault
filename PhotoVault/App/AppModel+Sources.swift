import AppKit
import Foundation
import GRDB
import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultEngine
import PhotoVaultStore

/// One-time imports from a folder on this Mac (Settings › Nguồn, menu bar card).
extension AppModel {
    var imports: [ImportSnapshot] { ImportQueue.merged(queued: queuedImports, running: snapshot?.imports ?? []) }
    var runningImports: [ImportSnapshot] { ImportProgressText.running(imports) }
    var finishedImports: [ImportSnapshot] { ImportProgressText.finished(imports) }

    /// Import needs the first baseline, because the same cycle that scans Photos runs it.
    var canStartImport: Bool { phase == .running }

    /// Asks for a folder, records the job and starts a cycle.
    func importFolder() {
        guard canStartImport else { return }
        do {
            guard let chosen = try FolderPicker.chooseImportFolder() else { return }
            beginFolderImport(chosen)
        } catch {
            reportBookmarkFailure()
        }
    }

    /// The provider's desktop app is installed (or its folder was seen). The sandbox cannot list
    /// `~/Library/CloudStorage`, so this asks Launch Services for the app; the listing only refines it.
    func syncedFolderDetection(_ provider: SyncedCloudProvider) -> SyncedCloudFolders.Detection {
        SyncedCloudFolders.detect(
            provider, home: Self.realHome,
            appInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
            list: { try? FileManager.default.contentsOfDirectory(atPath: $0.path) })
    }

    enum SyncedImportOutcome { case started, cancelled, useBrowser }

    /// Imports from the provider's folder synced to this Mac: a Mac-folder import, no sign-in with the provider.
    /// `.useBrowser` when the owner asks for the web flow instead.
    func importFromSyncedFolder(_ provider: SyncedCloudProvider) -> SyncedImportOutcome {
        guard canStartImport else { return .cancelled }
        do {
            switch try FolderPicker.chooseSyncedFolder(provider: provider, startAt: syncedFolderDetection(provider).startDirectory) {
            case .cancelled: return .cancelled
            case .useBrowser: return .useBrowser
            case .picked(let pick): beginFolderImport(pick); return .started
            }
        } catch {
            reportBookmarkFailure()
            return .cancelled
        }
    }

    /// The real home folder: `NSHomeDirectory()` is the sandbox container.
    private static var realHome: URL {
        getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir)) } ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    private func reportBookmarkFailure() {
        env?.log.log(.error, category: "import", "bookmark for the chosen folder failed")
        showNotice(tr(
            vi: "Không mở được thư mục này để đọc. Hãy chọn thư mục khác hoặc cấp quyền truy cập thư mục trong System Settings.",
            en: "This folder couldn’t be opened for reading. Choose another folder, or allow access to it in System Settings."), isError: true)
    }

    /// Records the job for a chosen folder and starts a cycle. A folder inside Google Drive's or Dropbox's synced
    /// folder is remembered as such, whichever menu entry it was chosen from.
    private func beginFolderImport(_ pick: FolderPicker.Pick) {
        guard let env else { return }
        let existing = destinations.compactMap { record in
            record.kind == .localFolder ? record.config.displayPath.map { (name: record.displayName, path: $0) } : nil
        }
        let candidates = [pick.url.path, pick.url.resolvingSymlinksInPath().path]
        for path in candidates {
            if let reason = ImportFolderGuard.conflict(candidate: path, destinations: existing, container: env.layout.root.resolvingSymlinksInPath().path)
                ?? ImportFolderGuard.conflict(candidate: path, destinations: existing, container: env.layout.root.path) {
                showNotice(reason, isError: true)
                return
            }
        }
        let source = AppEnvironment.makeFolderSource(id: .folder(), bookmark: pick.bookmark, store: env.store, log: env.log)
        let name = pick.url.lastPathComponent
        let synced = SyncedCloudFolders.provider(ofPath: pick.url.path, home: Self.realHome)
        let shown = SyncedCloudFolders.displayPath(pick.url.path, home: Self.realHome) ?? ImportLocationPath.mac(pick.url.path)
        let config = SourceConfig(
            bookmark: pick.bookmark, account: SyncedCloudFolders.account(ofPath: pick.url.path), locationPaths: [shown], syncedProvider: synced)
        Task {
            do {
                try await env.coordinator.startImport(source: source, kind: .localFolder, displayName: name, config: config)
                env.log.log(.info, category: "import", synced == nil ? "import started" : "synced cloud folder import started")
                requestSync(.manual)
                await refreshSnapshot()
            } catch {
                showError(error)
            }
        }
    }

    func cancelImport(_ id: SourceID) {
        guard let env else { return }
        // Still waiting for its turn: stop the start; its task deletes the stored sign-in.
        if let start = queuedStarts[id] {
            start.cancel()
            queuedImports.removeAll { $0.id == id }
            return
        }
        Task {
            do {
                try await env.coordinator.cancelImport(id)
                env.log.log(.info, category: "import", "import cancelled")
                await refreshSnapshot()
            } catch {
                showError(error)
            }
        }
    }

    /// Posts one notification when an import that was running at the last snapshot has completed.
    /// A job that is already finished when the app starts is only remembered.
    func noteImportProgress(_ snapshot: EngineSnapshot) async {
        let next = Dictionary(snapshot.imports.map { ($0.id, $0.status) }, uniquingKeysWith: { _, last in last })
        // Assigned before anything suspends: a second snapshot that arrives while a notification is
        // being posted must not see the old statuses and post the same completion again.
        let before = importStatuses
        importStatuses = next
        for item in ImportProgressText.newlyCompleted(before: before, imports: snapshot.imports) {
            guard let env, await notificationService.isAuthorized() else { continue }
            let text = item.found == 0
                ? ImportNotificationText.makeEmpty(folderName: item.displayName)
                : ImportNotificationText.make(folderName: item.displayName, imported: item.imported, known: item.duplicates)
            do {
                try await notificationService.postImportFinished(id: item.id, title: text.title, body: text.body)
                env.log.log(.info, category: "notification", "posted import finished")
            } catch {
                env.log.log(.error, category: "notification", "post failed: \(type(of: error))")
            }
        }
    }

    /// Live Photos assets, for the Photos row of the Sources tab.
    func photosAssetCount() async -> Int {
        guard let env else { return 0 }
        return (try? await env.store.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE source_id = 'photos' AND deleted_at IS NULL")
        }) ?? 0
    }
}
