import Foundation
import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultDrive
import PhotoVaultDropbox
import PhotoVaultEngine
import PhotoVaultStore

/// One-time imports from Google Drive (Google's desktop Picker) and Dropbox (a folder).
extension AppModel {
    var googleImportAvailable: Bool { env?.cloud.googleConfigured ?? false }
    var dropboxImportAvailable: Bool { env?.cloud.dropboxConfigured ?? false }

    // MARK: Google Drive

    /// Opens the Picker in the browser, stores the grant as `import-<id>` and starts the import.
    func importFromGoogleDrive() {
        guard let env, canStartImport, !cloudFlowBusy else { return }
        runCloudFlow { [self] in
            let picked = try await env.cloud.pickerFlow(onReadStep: readStepNotifier).run()
            // The account guard needs to know who signed in; without it nothing is stored and nothing starts.
            guard let email = picked.email?.trimmingCharacters(in: .whitespaces), !email.isEmpty else {
                env.log.log(.info, category: "import", "google import not started: account unknown")
                return showNotice(CloudImportText.accountUnverifiedStartNotice, isError: true)
            }
            // The owner may have pressed Cancel while the token was being exchanged.
            try Task.checkCancellation()
            let id = SourceID.folder()
            try DriveImportAuth.store(refreshToken: picked.refreshToken, for: id, in: env.cloud.keychain)
            let source = env.cloud.driveSource(id: id, pickedIds: picked.pickedIds, initial: (picked.accessToken, picked.expiresAt))
            let folderName = await source.singlePickedFolderName()
            let name = CloudImportText.googleDisplayName(singleFolderName: folderName, pickedCount: picked.pickedIds.count)
            var config = SourceConfig(
                account: email, remoteItems: picked.pickedIds,
                sidecarName: CloudImportText.googleSidecarName(singleFolderName: folderName, pickedCount: picked.pickedIds.count))
            if Task.isCancelled {
                _ = env.cloud.deleteTokens(accounts: [CloudTokenAccount.importGrant(id)])
                throw CancellationError()
            }
            enqueueImport(
                id: id, kind: .googleDrive, account: email, displayName: name, provider: "google drive") { [self] in
                // The walk runs here, after the sign-in row has left its browser step; it never fails the import.
                let locations = await source.pickedLocations()
                try Task.checkCancellation()
                config.locationPaths = locations?.paths
                config.locationURL = locations?.webURL
                queuedImports = ImportQueue.setting(ImportLocation.make(kind: .googleDrive, config: config), for: id, in: queuedImports)
                return try await env.coordinator.startImport(source: source, kind: .googleDrive, displayName: name, config: config)
            }
        }
    }

    // MARK: Dropbox

    /// Signs in when there is no account token. True when a token is stored afterwards.
    func ensureDropboxSignedIn() async -> Bool {
        guard let env, canStartImport, !cloudFlowBusy else { return false }
        if env.cloud.hasDropboxAccount() { return true }
        return await signInDropbox(env)
    }

    /// Client for the folder browser, bound to the account token.
    func dropboxBrowserClient() -> DropboxClient? {
        guard let cloud = env?.cloud else { return nil }
        return cloud.dropboxClient(authorizer: cloud.dropboxAuthorizer(account: CloudTokenAccount.dropbox))
    }

    /// Re-signs in to the Dropbox account used by the folder browser.
    func signInDropboxAgain() async -> Bool {
        guard let env, !cloudFlowBusy else { return false }
        return await signInDropbox(env)
    }

    private func signInDropbox(_ env: AppEnvironment) async -> Bool {
        let stored: Bool? = await trackedFlow { [self] in
            let signIn = try await env.cloud.dropboxAuth().signIn()
            try Task.checkCancellation()
            try await env.cloud.dropboxAuthorizer(account: CloudTokenAccount.dropbox).store(signIn)
            dropboxSignedIn = true
            env.log.log(.info, category: "import", "dropbox account signed in")
            return true
        }
        return stored == true
    }

    /// Copies the account token to `import-<id>` and starts importing `path` (`""` = the whole Dropbox).
    /// The account is required: it is what a later sign-in is checked against.
    func importDropboxFolder(path: String, email: String) async -> Bool {
        guard let env, canStartImport else { return false }
        guard !email.trimmingCharacters(in: .whitespaces).isEmpty else {
            showNotice(CloudImportText.accountUnverifiedStartNotice, isError: true)
            return false
        }
        let id = SourceID.folder()
        do {
            try Task.checkCancellation()
            try env.cloud.copyDropboxAccountToken(to: id)
        } catch {
            _ = env.cloud.deleteTokens(accounts: [CloudTokenAccount.importGrant(id)])
            reportCloudFlowError(error)
            return false
        }
        let name = CloudImportText.dropboxDisplayName(path: path)
        let source = env.cloud.dropboxSource(id: id, rootPath: path)
        let config = SourceConfig(account: email, remoteItems: [path], sidecarName: CloudImportText.dropboxSidecarName(path: path))
        enqueueImport(
            id: id, kind: .dropbox, account: email, displayName: name, provider: "dropbox",
            location: ImportLocation.make(kind: .dropbox, config: config)) {
            try await env.coordinator.startImport(source: source, kind: .dropbox, displayName: name, config: config)
        }
        return true
    }

    /// Removes the Dropbox account token. Imports keep their own tokens.
    func signOutDropbox() {
        guard let env else { return }
        let failed = env.cloud.deleteTokens(accounts: [CloudTokenAccount.dropbox])
        dropboxSignedIn = env.cloud.hasDropboxAccount()
        if failed > 0 {
            showNotice(tr(vi: "Không xoá được thông tin đăng nhập Dropbox.", en: "Could not remove the Dropbox sign-in."), isError: true)
        } else {
            env.log.log(.info, category: "import", "dropbox account signed out")
            showNotice(tr(vi: "Đã đăng xuất Dropbox.", en: "Signed out of Dropbox."))
        }
    }

    // MARK: Finished imports

    /// Deletes the stored sign-in of every import that is closed with no upload of its files left, and drops its
    /// adapter. Runs after each cycle; running it twice changes nothing. A destination added later finds the
    /// import without a sign-in and asks the owner for one ("Đăng nhập lại").
    func releaseFinishedImportGrants() async {
        guard let env else { return }
        let cloud = env.cloud
        let ids: [SourceID]
        do { ids = try await env.coordinator.closedImportsReadyToRelease(grantExists: { cloud.hasGrant($0) }) } catch {
            env.log.log(.error, category: "import", "could not list finished imports: \(type(of: error))")
            return
        }
        let coordinator = env.coordinator
        let outcome = await CloudImportKeychain.release(
            ids: ids, hasGrant: cloud.hasGrant, deleteGrant: { cloud.deleteTokens(accounts: [$0]) == 0 },
            dropAdapter: { await coordinator.releaseImportSource($0) })
        if outcome.released > 0 { env.log.log(.info, category: "import", "finished imports: \(outcome.released) sign-ins removed") }
        if outcome.failed > 0 { env.log.log(.error, category: "import", "finished imports: \(outcome.failed) sign-ins could not be removed") }
    }

    // MARK: Sign in again

    /// Reruns the sign-in of a held or finished import. It must be the account the import reads from; the
    /// import then carries on at once. Nothing changes when the owner chooses another account.
    func reconnectImport(_ item: ImportSnapshot) {
        guard let env else { return }
        guard !cloudFlowBusy else { return showNotice(CloudImportText.waitingForBrowser) }
        let id = item.id
        switch item.kind {
        case .googleDrive:
            runCloudFlow { [self] in
                let picked = try await env.cloud.pickerFlow(onReadStep: readStepNotifier).run()
                if CloudImportText.accountUnknown(expected: item.account, signedIn: picked.email) { return showNotice(CloudImportText.accountUnverifiedNotice, isError: true) }
                guard CloudImportText.isSameAccount(expected: item.account, signedIn: picked.email) else { return refuseOtherAccount(item) }
                // Google lets the app keep reading what it could read before, so the new pick is added to the old one.
                var config = try await env.store.read { db in try SourceRepository.fetch(db, id: id)?.config } ?? SourceConfig()
                let merged = CloudImportText.mergedPicks(existing: config.remoteItems ?? [], picked: picked.pickedIds)
                try Task.checkCancellation()
                try DriveImportAuth.store(refreshToken: picked.refreshToken, for: id, in: env.cloud.keychain)
                config.remoteItems = merged
                config.account = config.account ?? picked.email
                let stored = config
                try await env.store.write { db in try SourceRepository.setConfig(db, id: id, stored) }
                await env.coordinator.registerSources([
                    env.cloud.driveSource(id: id, pickedIds: merged, initial: (picked.accessToken, picked.expiresAt))])
                resumeInBackground(id)
            }
        case .dropbox:
            runCloudFlow { [self] in
                let signIn = try await env.cloud.dropboxAuth().signIn()
                if CloudImportText.accountUnknown(expected: item.account, signedIn: signIn.email) { return showNotice(CloudImportText.accountUnverifiedNotice, isError: true) }
                guard CloudImportText.isSameAccount(expected: item.account, signedIn: signIn.email) else { return refuseOtherAccount(item) }
                try Task.checkCancellation()
                try await env.cloud.dropboxAuthorizer(account: CloudTokenAccount.importGrant(id)).store(signIn)
                // A job whose token was missing at launch has no adapter yet.
                let root = try await env.store.read { db in try SourceRepository.fetch(db, id: id)?.config.remoteItems?.first } ?? ""
                await env.coordinator.registerSources([env.cloud.dropboxSource(id: id, rootPath: root)])
                resumeInBackground(id)
            }
        case .localFolder, .photos:
            break
        }
    }

    private func refuseOtherAccount(_ item: ImportSnapshot) {
        env?.log.log(.info, category: "import", "sign-in refused: another account")
        showNotice(CloudImportText.wrongAccountNotice(expected: item.account), isError: true)
    }

    // MARK: Shared

    /// Tells the row that Google's second consent opened. A notice that lands after the flow moved on is ignored.
    private var readStepNotifier: @Sendable () -> Void {
        let flow = cloudFlowID
        return { [weak self] in Task { @MainActor in self?.cloudFlow.reachReadStep(flow) } }
    }

    /// Lists the import as "waiting for its turn" and records it in a task of its own: the engine runs the start
    /// between sync passes, which can take long, and the owner may close the window meanwhile. Cancelling the
    /// queued entry cancels the start and deletes the stored sign-in; so does a start that fails.
    func enqueueImport(id: SourceID, kind: SourceKind, account: String?, syncedProvider: SyncedCloudProvider? = nil, displayName: String,
                       provider: String, location: ImportLocation? = nil, start: @escaping @MainActor () async throws -> SourceID) {
        queuedImports.append(ImportQueue.snapshot(
            id: id, kind: kind, account: account, syncedProvider: syncedProvider, displayName: displayName, now: Date(), location: location))
        queuedStarts[id] = Task { @MainActor [self] in
            defer {
                queuedImports.removeAll { $0.id == id }
                queuedStarts[id] = nil
            }
            do {
                try Task.checkCancellation()
                _ = try await start()
                // Recorded: a Cancel from here on must reach the engine, not this finished task.
                queuedStarts[id] = nil
                if Task.isCancelled {
                    try await env?.coordinator.cancelImport(id)
                    return
                }
            } catch {
                _ = env?.cloud.deleteTokens(accounts: [CloudTokenAccount.importGrant(id)])
                reportCloudFlowError(error)
                return
            }
            didStartCloudImport(provider)
            await refreshSnapshot()
        }
    }

    /// Resumes a signed-in-again import in a task of its own; its row says "Signed in" while it waits for the engine.
    private func resumeInBackground(_ id: SourceID) {
        resumingImports.insert(id)
        Task { @MainActor [self] in
            await didReconnectCloudImport(id)
            resumingImports.remove(id)
        }
    }

    /// Runs a browser flow as a task the owner can cancel while it waits for the browser.
    private func runCloudFlow(_ body: @escaping @MainActor () async throws -> Void) {
        cloudFlowID = cloudFlow.begin()
        let flow = cloudFlowID
        Task { _ = await trackedFlow(flow: flow, body) }
    }

    /// Marks the flow busy, keeps a way to cancel it, and reports its failure. Nil when it failed or was cancelled.
    private func trackedFlow<T: Sendable>(flow: Int? = nil, _ body: @escaping @MainActor () async throws -> T) async -> T? {
        let flow = flow ?? cloudFlow.begin()
        cloudFlowID = flow
        let task = Task { @MainActor in try await body() }
        cloudFlowCancel = { task.cancel() }
        defer {
            cloudFlow.end(flow)
            cloudFlowCancel = nil
        }
        do { return try await task.value } catch {
            // Pressing Cancel is quiet, whatever error the cancelled step ended with.
            if !task.isCancelled { reportCloudFlowError(error) }
            return nil
        }
    }

    /// The owner gave up waiting for the browser: the flow's task is cancelled, which closes its local listener.
    func cancelCloudFlow() { cloudFlowCancel?() }

    func didStartCloudImport(_ provider: String) {
        env?.log.log(.info, category: "import", "\(provider) import started")
        requestSync(.manual)
        Task { await refreshSnapshot() }
    }

    /// Clears the hold so the import resumes in the next cycle, not after the cooldown.
    private func didReconnectCloudImport(_ id: SourceID) async {
        env?.log.log(.info, category: "import", "cloud import signed in again")
        do { try await env?.coordinator.resumeImportAfterSignIn(id) } catch {
            env?.log.log(.error, category: "import", "could not resume the import: \(type(of: error))")
        }
        requestSync(.manual)
        await refreshSnapshot()
    }

    /// Cancel and timeout are the owner's own doing: quiet or a short notice, never an error banner.
    func reportCloudFlowError(_ error: any Error) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        if case SourceError.cancelled = error { return }
        if let picker = error as? PickerError {
            switch picker {
            case .cancelled: return
            case .timedOut: showNotice(Self.signInTimedOut)
            case .nothingPicked: showNotice(tr(vi: "Chưa chọn ảnh hay thư mục nào.", en: "No photos or folders were chosen."))
            case .selectionTooLarge:
                showNotice(tr(vi: "Đã chọn quá nhiều mục cùng lúc. Hãy chọn ít hơn hoặc chia làm nhiều lần.", en: "Too many items were selected at once. Pick fewer, or import in several rounds."), isError: true)
            case .browserUnavailable: showNotice(Self.browserUnavailable, isError: true)
            case .readAccessDenied:
                showNotice(tr(
                    vi: "Bạn cần cho phép PhotoVault xem file trong Drive để nhập thư mục (bước 2). Hãy thử lại và giữ ô “Xem và tải xuống mọi file trên Google Drive” được chọn.",
                    en: "PhotoVault needs permission to see your Drive files to import a folder (step 2). Try again and keep “See and download all your Google Drive files” ticked."), isError: true)
            case .pickAccessDenied:
                showNotice(tr(
                    vi: "Bạn cần cho phép PhotoVault truy cập các file bạn chọn trong Drive. Hãy thử lại và giữ ô “Xem, chỉnh sửa, tạo và xóa các file cụ thể trong Google Drive” được chọn.",
                    en: "PhotoVault needs permission for the Drive files you pick. Try again and keep “See, edit, create, and delete only the specific Google Drive files you use with this app” ticked."), isError: true)
            case .accountMismatch:
                showNotice(tr(
                    vi: "Bước 2 dùng khác tài khoản Google. Hãy thử lại và chọn đúng tài khoản đã dùng để chọn thư mục.",
                    en: "Step 2 used a different Google account. Try again and choose the same account you used to pick the folder."), isError: true)
            case .tokenMissing: showNotice(tr(vi: "Google không trả quyền truy cập. Hãy thử lại.", en: "Google did not grant access. Try again."), isError: true)
            }
        } else if let dropbox = error as? DropboxAuthError {
            switch dropbox {
            case .cancelled: return
            case .timedOut: showNotice(Self.signInTimedOut)
            case .browserUnavailable: showNotice(Self.browserUnavailable, isError: true)
            case .denied: return // The owner pressed Cancel on Dropbox's page.
            case .failed: showNotice(tr(vi: "Đăng nhập Dropbox không thành công. Hãy thử lại.", en: "Dropbox sign-in did not work. Try again."), isError: true)
            case .portInUse:
                showNotice(tr(
                    vi: "Một ứng dụng khác đang dùng cổng đăng nhập Dropbox. Đóng nó rồi thử lại.",
                    en: "Another app is using the Dropbox sign-in port. Close it and try again."), isError: true)
            case .malformedResponse: showNotice(tr(vi: "Dropbox trả lời không hợp lệ. Hãy thử lại.", en: "Dropbox sent an unexpected answer. Try again."), isError: true)
            }
        } else if case DestinationError.reauthRequired = error {
            showNotice(tr(vi: "Cần đăng nhập Dropbox lại.", en: "Sign in to Dropbox again."), isError: true)
        } else if case SourceError.accessRevoked = error {
            showNotice(tr(vi: "Cần đăng nhập Dropbox lại.", en: "Sign in to Dropbox again."), isError: true)
        } else if error is SourceError {
            showNotice(tr(vi: "Không kết nối được tới Dropbox. Kiểm tra mạng rồi thử lại.", en: "Can’t reach Dropbox. Check the network and try again."), isError: true)
        } else {
            showError(error)
        }
    }

    private static var signInTimedOut: String { tr(vi: "Hết thời gian chờ đăng nhập. Hãy thử lại.", en: "Sign-in timed out. Try again.") }
    private static var browserUnavailable: String { tr(vi: "Không mở được trình duyệt.", en: "Could not open the browser.") }
}
