import AppKit
import Foundation
import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultDrive
import PhotoVaultDropbox
import PhotoVaultEngine
import PhotoVaultPhotos

/// Builds the adapters and sign-in flows of Google Drive and Dropbox imports. One Keychain store holds
/// every token: `import-<id>` per import and `dropbox-account` for the folder browser.
struct CloudImportServices: Sendable {
    let googleConfig: OAuthConfig
    let oauth: OAuthClient
    let transport: any HTTPTransport
    let keychain: any KeychainStore
    let dropboxAppKey: String
    let scratchDirectory: URL

    var googleConfigured: Bool { !googleConfig.clientID.isEmpty }
    var dropboxConfigured: Bool { !dropboxAppKey.isEmpty }

    static let openURL: URLOpening = { url in await MainActor.run { NSWorkspace.shared.open(url) } }

    // MARK: Tokens

    func hasGrant(_ id: SourceID) -> Bool {
        ((try? keychain.read(account: CloudImportKeychain.importAccount(id))) ?? nil) != nil
    }

    func hasDropboxAccount() -> Bool {
        ((try? keychain.read(account: CloudImportKeychain.dropboxAccount)) ?? nil) != nil
    }

    func copyDropboxAccountToken(to id: SourceID) throws {
        guard let token = try keychain.read(account: CloudImportKeychain.dropboxAccount) else { throw DestinationError.reauthRequired }
        try keychain.write(token, account: CloudImportKeychain.importAccount(id))
    }

    /// Deletes every named item; returns how many could not be deleted.
    func deleteTokens(accounts: [String]) -> Int {
        accounts.reduce(0) { failures, account in
            do { try keychain.delete(account: account); return failures } catch { return failures + 1 }
        }
    }

    // MARK: Google Drive

    func pickerFlow() -> GooglePickerFlow {
        GooglePickerFlow(config: googleConfig, transport: transport, openURL: Self.openURL)
    }

    func driveSource(id: SourceID, pickedIds: [String], initial: (accessToken: String, expiresAt: Date)? = nil) -> DriveImportSource {
        let auth = DriveImportAuth(sourceId: id, oauth: oauth, keychain: keychain, initial: initial)
        return DriveImportSource(
            id: id, pickedIds: pickedIds, auth: auth, transport: transport,
            scratchDirectory: scratchDirectory, metadata: ImageIOMetadataReader())
    }

    // MARK: Dropbox

    func dropboxAuth() -> DropboxAuth {
        DropboxAuth(appKey: dropboxAppKey, transport: transport, openURL: Self.openURL)
    }

    func dropboxAuthorizer(account: String) -> DropboxTokenAuthorizer {
        DropboxTokenAuthorizer(auth: dropboxAuth(), keychain: keychain, keychainAccount: account)
    }

    func dropboxClient(authorizer: DropboxTokenAuthorizer) -> DropboxClient {
        DropboxClient(tokens: authorizer, transport: transport)
    }

    func dropboxSource(id: SourceID, rootPath: String) -> DropboxImportSource {
        let authorizer = dropboxAuthorizer(account: CloudImportKeychain.importAccount(id))
        return DropboxImportSource(
            id: id, rootPath: rootPath, client: dropboxClient(authorizer: authorizer),
            scratchDirectory: scratchDirectory, metadata: ImageIOMetadataReader())
    }
}
