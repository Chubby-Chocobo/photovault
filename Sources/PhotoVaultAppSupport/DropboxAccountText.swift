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
        return tr(vi: "Dropbox: đã đăng nhập bằng \(email)", en: "Dropbox: signed in as \(email)")
    }
}

/// Finds the e-mail of the Dropbox browsing account. A token from an older version has none stored: Dropbox
/// is asked once and the answer kept, unless the owner signed out or signed in again while it was in flight.
public enum DropboxEmailRefresh {
    /// The e-mail to show, or nil when unknown. `save` runs only while the same sign-in is still in place.
    @MainActor
    public static func resolve(
        signedIn: () -> Bool, tokenPresent: () -> Bool, stored: () -> String?,
        fetch: () async throws -> String, save: (String) throws -> Void
    ) async -> String? {
        if let known = stored() { return known }
        guard signedIn() else { return nil }
        let fetched: String
        do { fetched = try await fetch() } catch { return nil }
        // Something else may have changed the account while Dropbox was answering.
        if let now = stored() { return now }
        guard signedIn(), tokenPresent() else { return nil }
        do { try save(fetched) } catch { return fetched }
        return fetched
    }
}
