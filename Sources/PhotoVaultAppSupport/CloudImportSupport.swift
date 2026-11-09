import Foundation
import PhotoVaultCore
import PhotoVaultEngine

/// Text and rules for imports from Google Drive and Dropbox. Names and emails are shown in the app
/// only; they never reach logs.
public enum CloudImportText {
    /// "Thư mục trên Mac", "Google Drive · email", "Dropbox · email".
    public static func providerLabel(kind: SourceKind, account: String?) -> String {
        let name: String
        switch kind {
        case .googleDrive: name = "Google Drive"
        case .dropbox: name = "Dropbox"
        case .localFolder, .photos: return tr(vi: "Thư mục trên Mac", en: "Folder on this Mac")
        }
        guard let account = account?.trimmingCharacters(in: .whitespaces), !account.isEmpty else { return name }
        return "\(name) · \(account)"
    }

    /// The single picked folder's name; otherwise a count of the picked items.
    public static func googleDisplayName(singleFolderName: String?, pickedCount: Int) -> String {
        if let name = singleFolderName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, pickedCount == 1 { return name }
        let number = VietnameseFormat.integer(pickedCount)
        return tr(vi: "\(number) mục từ Google Drive", en: "\(number) \(L10n.plural(pickedCount, one: "item", other: "items")) from Google Drive")
    }

    /// Name of an import of `path` (`""` = the whole account).
    public static func dropboxDisplayName(path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init)
        return last ?? tr(vi: "Toàn bộ Dropbox", en: "All of Dropbox")
    }

    /// Shown for a finished Google Drive import that read no file: Google often lets the app read a
    /// picked folder's own contents only when the files are selected too.
    public static func emptyGoogleHint(_ item: ImportSnapshot) -> String? {
        guard item.kind == .googleDrive, item.status == .completed, item.found == 0 else { return nil }
        return tr(
            vi: "Không đọc được ảnh nào. Hãy nhập lại và chọn ảnh bên trong thư mục (⌘A để chọn tất cả), không chỉ chọn thư mục.",
            en: "No photos could be read. Import again and select the photos inside the folder (⌘A selects all), not just the folder.")
    }

    /// A cloud import the provider no longer lets in: an open one is held, a finished one waits for its files.
    public static func needsSignIn(_ item: ImportSnapshot) -> Bool {
        (item.kind == .googleDrive || item.kind == .dropbox) && item.statusReason == "signInRequired"
    }

    /// Shown when the owner signed in to another account than the import reads from.
    public static func wrongAccountNotice(expected: String?) -> String {
        let email = expected ?? tr(vi: "đã dùng trước đó", en: "used before")
        return tr(vi: "Hãy đăng nhập đúng tài khoản \(email)", en: "Sign in with the account \(email)")
    }

    /// The ids of a new pick added to the ones the import already reads, in order and without repeats.
    public static func mergedPicks(existing: [String], picked: [String]) -> [String] {
        var seen = Set<String>()
        return (existing + picked).filter { seen.insert($0).inserted }
    }

    /// Case-insensitive; an import with no recorded account accepts any.
    /// The provider did not say who signed in (its account call failed), so nothing can be compared yet.
    public static func accountUnknown(expected: String?, signedIn: String?) -> Bool {
        let known = { (value: String?) in !(value?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) }
        return known(expected) && !known(signedIn)
    }

    public static var accountUnverifiedNotice: String {
        tr(vi: "Chưa kiểm tra được tài khoản vừa đăng nhập. Hãy thử lại.", en: "The signed-in account could not be checked. Try again.")
    }

    public static func isSameAccount(expected: String?, signedIn: String?) -> Bool {
        guard let expected = expected?.trimmingCharacters(in: .whitespaces), !expected.isEmpty else { return true }
        guard let signedIn = signedIn?.trimmingCharacters(in: .whitespaces), !signedIn.isEmpty else { return false }
        return expected.caseInsensitiveCompare(signedIn) == .orderedSame
    }
}

/// Keychain items that belong to cloud imports and the Dropbox account.
public enum CloudImportKeychain {
    /// Every item Factory Reset removes, found by listing the Keychain, so a grant whose import row is
    /// missing or unreadable is removed too.
    public static func accountsToDelete(stored: [String]) -> [String] { stored.filter(CloudTokenAccount.isCloudItem) }

    /// Imports to register at launch: Mac folders as stored, cloud imports only while their grant exists.
    public static func registrable(_ rows: [SourceRecord], hasGrant: (SourceID) -> Bool) -> [SourceRecord] {
        rows.filter { row in
            switch row.kind {
            case .localFolder: row.config.bookmark != nil
            case .googleDrive, .dropbox: hasGrant(row.id)
            case .photos: false
            }
        }
    }
}
