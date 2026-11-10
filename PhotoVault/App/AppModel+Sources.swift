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
    var finishedImports: [ImportSnapshot] { ImportQueueLayout.finishedRows(imports) }
    /// Running imports first, then the ones waiting for the engine, numbered.
    var queueRows: [ImportQueueRow] { ImportQueueLayout.queueRows(imports) }

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

    /// For views: true when the provider's desktop app was found at the last refresh. Reads only, so it is safe in `body`.
    func syncedAvailable(_ provider: SyncedCloudProvider) -> Bool { syncedFolders[provider]?.isAvailable == true }

    /// The provider's desktop app is installed (or its folder was seen), as of the last `refreshSyncedFolders()`.
    func syncedFolderDetection(_ provider: SyncedCloudProvider) -> SyncedCloudFolders.Detection {
        if let known = syncedFolders[provider] { return known }
        refreshSyncedFolders()
        return syncedFolders[provider] ?? SyncedCloudFolders.detect(provider, home: Self.realHome, appInstalled: { _ in false }, list: { _ in nil })
    }

    /// Asks Launch Services for the desktop apps. The sandbox cannot list `~/Library/CloudStorage`: that is tried
    /// until it is refused once, then never again in this launch, so there is no violation per redraw.
    func refreshSyncedFolders() {
        let home = Self.realHome
        for provider in SyncedCloudProvider.allCases {
            syncedFolders[provider] = SyncedCloudFolders.detect(
                provider, home: home,
                appInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
                list: { [self] url in
                    guard !folderListingRefused else { return nil }
                    do { return try FileManager.default.contentsOfDirectory(atPath: url.path) } catch {
                        folderListingRefused = true
                        return nil
                    }
                })
        }
    }

    /// Imports from the provider's folder synced to this Mac: a Mac-folder import, no sign-in with the provider.
    func importFromSyncedFolder(_ provider: SyncedCloudProvider) {
        guard canStartImport else { return }
        do {
            guard let pick = try FolderPicker.chooseSyncedFolder(provider: provider, startAt: syncedFolderDetection(provider).startDirectory) else { return }
            beginFolderImport(pick)
        } catch {
            reportBookmarkFailure()
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
            bookmark: pick.bookmark, account: SyncedCloudFolders.account(ofPath: pick.url.path, home: Self.realHome), locationPaths: [shown], syncedProvider: synced)
        // Listed at once as "waiting for its turn": the engine records the import between sync passes, which can take
        // long, and the start must survive the Settings window closing.
        enqueueImport(
            id: source.id, kind: .localFolder, account: config.account, syncedProvider: synced, displayName: name,
            provider: synced == nil ? "folder" : "synced cloud folder", location: ImportLocation.make(kind: .localFolder, config: config)) {
            try await env.coordinator.startImport(source: source, kind: .localFolder, displayName: name, config: config)
        }
    }

    /// What a queued entry says while it waits: the status and why. The place in line is the row's badge only.
    func queueWait(for item: ImportSnapshot) -> (title: String, reason: String)? {
        guard ImportQueue.isQueued(item) else { return nil }
        return (ImportProgressText.statusLabel(item), engineWaitReason)
    }

    func isCancelling(_ item: ImportSnapshot) -> Bool { ImportProgressText.isCancelling(item, pending: cancellingImports) }

    /// Why a signed-in-again import or a cancel waits.
    var engineWaitReason: String { ImportQueue.waitReason(uploading: !transfers.isEmpty) }

    func cancelImport(_ id: SourceID) {
        guard let env else { return }
        // Still waiting for its turn: stop the start; its task deletes the stored sign-in.
        if let start = queuedStarts[id] {
            start.cancel()
            queuedImports.removeAll { $0.id == id }
            return
        }
        // The cancel is a command that waits for the engine's turn; the row says so meanwhile.
        cancellingImports.insert(id)
        Task {
            defer { cancellingImports.remove(id) }
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
