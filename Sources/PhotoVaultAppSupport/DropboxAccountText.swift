import Foundation
import PhotoVaultCore

/// The Dropbox account the folder browser is signed in with. The e-mail is shown in Settings only; it
/// is never logged, put in an activity row or sent in a notification.
public enum DropboxAccountText {
    public static func line(signedIn: Bool, email: String?) -> String {
        guard signedIn else { return tr(vi: "Dropbox: chưa đăng nhập", en: "Dropbox: not signed in") }
        guard let email = email?.trimmingCharacters(in: .whitespaces), !email.isEmpty else {
            return tr(vi: "Dropbox: đã đăng nhập", en: "Dropbox: signed in")
        }
        return tr(vi: "Dropbox: đã đăng nhập \(email)", en: "Dropbox: signed in as \(email)")
    }
}
