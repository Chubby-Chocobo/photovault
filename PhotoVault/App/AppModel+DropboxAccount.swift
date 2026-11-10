import Foundation
import PhotoVaultAppSupport
import PhotoVaultCore

extension AppModel {
    var dropboxAccountLine: String { DropboxAccountText.line(signedIn: dropboxSignedIn, email: dropboxEmail) }

    /// Reads the stored e-mail of the Dropbox browsing account. A token from an older version has none: it
    /// is asked from Dropbox once and kept. Offline, the line shows "signed in" without it until next time.
    func refreshDropboxEmail() async {
        guard dropboxSignedIn, let cloud = env?.cloud, let client = dropboxBrowserClient() else {
            dropboxEmail = nil
            return
        }
        let email = await DropboxEmailRefresh.resolve(
            signedIn: { self.dropboxSignedIn }, tokenPresent: { cloud.hasDropboxAccount() }, stored: { cloud.storedDropboxEmail() },
            fetch: { try await client.currentAccountEmail() }, save: { try cloud.storeDropboxEmail($0) })
        dropboxEmail = dropboxSignedIn ? email : nil
    }
}
