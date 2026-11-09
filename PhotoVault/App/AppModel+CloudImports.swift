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
            let picked = try await env.cloud.pickerFlow().run()
            let id = SourceID.folder()
            try DriveImportAuth.store(refreshToken: picked.refreshToken, for: id, in: env.cloud.keychain)
            let source = env.cloud.driveSource(id: id, pickedIds: picked.pickedIds, initial: (picked.accessToken, picked.expiresAt))
            let name = CloudImportText.googleDisplayName(singleFolderName: await source.singlePickedFolderName(), pickedCount: picked.pickedIds.count)
            do {
                try await env.coordinator.startImport(
                    source: source, kind: .googleDrive, displayName: name,
                    config: SourceConfig(account: picked.email, remoteItems: picked.pickedIds))
            } catch {
                try? DriveImportAuth.removeGrant(for: id, from: env.cloud.keychain)
                throw error
            }
            didStartCloudImport("google drive")
        }
    }

    // MARK: Dropbox

    /// Signs in when there is no account token. True when a token is stored afterwards.
    func ensureDropboxSignedIn() async -> Bool {
        guard let env, canStartImport, !cloudFlowBusy else { return false }
        if env.cloud.hasDropboxAccount() { return true }
        cloudFlowBusy = true
        defer { cloudFlowBusy = false }
        do {
            let signIn = try await env.cloud.dropboxAuth().signIn()
            try await env.cloud.dropboxAuthorizer(account: CloudTokenAccount.dropbox).store(signIn)
            dropboxSignedIn = true
            env.log.log(.info, category: "import", "dropbox account signed in")
            return true
        } catch {
            reportCloudFlowError(error)
            return false
        }
    }

    /// Client for the folder browser, bound to the account token.
    func dropboxBrowserClient() -> DropboxClient? {
        guard let cloud = env?.cloud else { return nil }
        return cloud.dropboxClient(authorizer: cloud.dropboxAuthorizer(account: CloudTokenAccount.dropbox))
    }

    /// Re-signs in to the Dropbox account used by the folder browser.
    func signInDropboxAgain() async -> Bool {
        guard let env, !cloudFlowBusy else { return false }
        cloudFlowBusy = true
        defer { cloudFlowBusy = false }
        do {
            let signIn = try await env.cloud.dropboxAuth().signIn()
            try await env.cloud.dropboxAuthorizer(account: CloudTokenAccount.dropbox).store(signIn)
            dropboxSignedIn = true
            return true
        } catch {
            reportCloudFlowError(error)
            return false
        }
    }

    /// Copies the account token to `import-<id>` and starts importing `path` (`""` = the whole Dropbox).
    func importDropboxFolder(path: String, email: String?) async -> Bool {
        guard let env, canStartImport else { return false }
        let id = SourceID.folder()
        do {
            try env.cloud.copyDropboxAccountToken(to: id)
            do {
                try await env.coordinator.startImport(
                    source: env.cloud.dropboxSource(id: id, rootPath: path), kind: .dropbox,
                    displayName: CloudImportText.dropboxDisplayName(path: path),
                    config: SourceConfig(account: email, remoteItems: [path]))
            } catch {
                _ = env.cloud.deleteTokens(accounts: [CloudTokenAccount.importGrant(id)])
                throw error
            }
            didStartCloudImport("dropbox")
            return true
        } catch {
            reportCloudFlowError(error)
            return false
        }
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

    // MARK: Sign in again

    /// Reruns the sign-in of a held or finished import. It must be the account the import reads from; the
    /// import then carries on at once. Nothing changes when the owner chooses another account.
    func reconnectImport(_ item: ImportSnapshot) {
        guard let env, !cloudFlowBusy else { return }
        let id = item.id
        switch item.kind {
        case .googleDrive:
            runCloudFlow { [self] in
                let picked = try await env.cloud.pickerFlow().run()
                guard CloudImportText.isSameAccount(expected: item.account, signedIn: picked.email) else { return refuseOtherAccount(item) }
                // Google lets the app keep reading what it could read before, so the new pick is added to the old one.
                var config = try await env.store.read { db in try SourceRepository.fetch(db, id: id)?.config } ?? SourceConfig()
                let merged = CloudImportText.mergedPicks(existing: config.remoteItems ?? [], picked: picked.pickedIds)
                try DriveImportAuth.store(refreshToken: picked.refreshToken, for: id, in: env.cloud.keychain)
                config.remoteItems = merged
                config.account = config.account ?? picked.email
                let stored = config
                try await env.store.write { db in try SourceRepository.setConfig(db, id: id, stored) }
                await env.coordinator.registerSources([
                    env.cloud.driveSource(id: id, pickedIds: merged, initial: (picked.accessToken, picked.expiresAt))])
                await didReconnectCloudImport(id)
            }
        case .dropbox:
            runCloudFlow { [self] in
                let signIn = try await env.cloud.dropboxAuth().signIn()
                guard CloudImportText.isSameAccount(expected: item.account, signedIn: signIn.email) else { return refuseOtherAccount(item) }
                try await env.cloud.dropboxAuthorizer(account: CloudTokenAccount.importGrant(id)).store(signIn)
                // A job whose token was missing at launch has no adapter yet.
                let root = try await env.store.read { db in try SourceRepository.fetch(db, id: id)?.config.remoteItems?.first } ?? ""
                await env.coordinator.registerSources([env.cloud.dropboxSource(id: id, rootPath: root)])
                await didReconnectCloudImport(id)
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

    private func runCloudFlow(_ body: @escaping @MainActor () async throws -> Void) {
        cloudFlowBusy = true
        Task {
            defer { cloudFlowBusy = false }
            do { try await body() } catch { reportCloudFlowError(error) }
        }
    }

    private func didStartCloudImport(_ provider: String) {
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
        if let picker = error as? PickerError {
            switch picker {
            case .cancelled: return
            case .timedOut: showNotice(Self.signInTimedOut)
            case .nothingPicked: showNotice(tr(vi: "Chưa chọn ảnh hay thư mục nào.", en: "No photos or folders were chosen."))
            case .browserUnavailable: showNotice(Self.browserUnavailable, isError: true)
            case .tokenMissing: showNotice(tr(vi: "Google không trả quyền truy cập. Hãy thử lại.", en: "Google did not grant access. Try again."), isError: true)
            }
        } else if let dropbox = error as? DropboxAuthError {
            switch dropbox {
            case .cancelled: return
            case .timedOut: showNotice(Self.signInTimedOut)
            case .browserUnavailable: showNotice(Self.browserUnavailable, isError: true)
            case .denied: showNotice(tr(vi: "Dropbox đã từ chối quyền truy cập.", en: "Dropbox refused access."), isError: true)
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
