import Foundation
import PhotoVaultCore

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
