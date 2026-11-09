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
            try await env.cloud.dropboxAuthorizer(account: CloudImportKeychain.dropboxAccount).store(signIn)
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
        return cloud.dropboxClient(authorizer: cloud.dropboxAuthorizer(account: CloudImportKeychain.dropboxAccount))
    }

    /// Re-signs in to the Dropbox account used by the folder browser.
    func signInDropboxAgain() async -> Bool {
        guard let env, !cloudFlowBusy else { return false }
        cloudFlowBusy = true
        defer { cloudFlowBusy = false }
        do {
            let signIn = try await env.cloud.dropboxAuth().signIn()
            try await env.cloud.dropboxAuthorizer(account: CloudImportKeychain.dropboxAccount).store(signIn)
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
                _ = env.cloud.deleteTokens(accounts: [CloudImportKeychain.importAccount(id)])
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
        let failed = env.cloud.deleteTokens(accounts: [CloudImportKeychain.dropboxAccount])
        dropboxSignedIn = env.cloud.hasDropboxAccount()
        if failed > 0 {
            showNotice(tr(vi: "Không xoá được thông tin đăng nhập Dropbox.", en: "Could not remove the Dropbox sign-in."), isError: true)
        } else {
            env.log.log(.info, category: "import", "dropbox account signed out")
            showNotice(tr(vi: "Đã đăng xuất Dropbox.", en: "Signed out of Dropbox."))
        }
    }

    // MARK: Sign in again

    /// Reruns the start flow of a held import and replaces its token; the engine continues by itself.
    func reconnectImport(_ item: ImportSnapshot) {
        guard let env, !cloudFlowBusy else { return }
        let id = item.id
        switch item.kind {
        case .googleDrive:
            runCloudFlow { [self] in
                let picked = try await env.cloud.pickerFlow().run()
                try DriveImportAuth.store(refreshToken: picked.refreshToken, for: id, in: env.cloud.keychain)
                // The new grant covers what was picked now, so the import follows this pick.
                let config = SourceConfig(account: picked.email ?? item.account, remoteItems: picked.pickedIds)
                try await env.store.write { db in try SourceRepository.setConfig(db, id: id, config) }
                await env.coordinator.registerSources([
                    env.cloud.driveSource(id: id, pickedIds: picked.pickedIds, initial: (picked.accessToken, picked.expiresAt))])
                didReconnectCloudImport()
            }
        case .dropbox:
            runCloudFlow { [self] in
                let signIn = try await env.cloud.dropboxAuth().signIn()
                try await env.cloud.dropboxAuthorizer(account: CloudImportKeychain.importAccount(id)).store(signIn)
                // A job whose token was missing at launch has no adapter yet.
                let root = try await env.store.read { db in try SourceRepository.fetch(db, id: id)?.config.remoteItems?.first } ?? ""
                await env.coordinator.registerSources([env.cloud.dropboxSource(id: id, rootPath: root)])
                didReconnectCloudImport()
            }
        case .localFolder, .photos:
            break
        }
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

    private func didReconnectCloudImport() {
        env?.log.log(.info, category: "import", "cloud import signed in again")
        requestSync(.manual)
        Task { await refreshSnapshot() }
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
