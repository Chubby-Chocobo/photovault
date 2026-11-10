import Foundation
import PhotoVaultAppSupport
import PhotoVaultCore

extension AppModel {
    var dropboxAccountLine: String { DropboxAccountText.line(signedIn: dropboxSignedIn, email: dropboxEmail) }

    /// Reads the stored e-mail of the Dropbox browsing account. A token from an older version has none: it
    /// is asked from Dropbox once and kept. Offline, the line shows "signed in" without it until next time.
    func refreshDropboxEmail() async {
        guard dropboxSignedIn, let cloud = env?.cloud else {
            dropboxEmail = nil
            return
        }
        if let stored = cloud.storedDropboxEmail() {
            dropboxEmail = stored
            return
        }
        guard let client = dropboxBrowserClient() else { return }
        do {
            let email = try await client.currentAccountEmail()
            try cloud.storeDropboxEmail(email)
            if dropboxSignedIn { dropboxEmail = email }
        } catch {
            dropboxEmail = nil
        }
    }
}
