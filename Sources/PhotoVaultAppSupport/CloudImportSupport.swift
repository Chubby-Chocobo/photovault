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

    /// The name sidecars carry, which does not change with the app language: the single picked folder's name,
    /// otherwise the provider's.
    public static func googleSidecarName(singleFolderName: String?, pickedCount: Int) -> String {
        if let name = singleFolderName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, pickedCount == 1 { return name }
        return "Google Drive"
    }

    public static func dropboxSidecarName(path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? "Dropbox"
    }

    /// Name of an import of `path` (`""` = the whole account).
    public static func dropboxDisplayName(path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init)
        return last ?? tr(vi: "Toàn bộ Dropbox", en: "All of Dropbox")
    }

    /// Shown for a finished import whose listing found no photo or video the app could read, so it never
    /// looks like a silent success. A Google Drive import also gets the way to import again: imports made before
    /// Drive reading was granted only saw the picked folder itself.
    public static func emptyImportNotice(_ item: ImportSnapshot) -> String? {
        guard item.status == .completed, item.found == 0 else { return nil }
        let base = tr(vi: "Mục đã chọn không có ảnh hay video nào mà app đọc được.", en: "The selection had no photos or videos the app could read.")
        guard item.kind == .googleDrive else { return base }
        return base + " " + tr(
            vi: "Hãy nhập lại: Nhập ảnh… › Từ Google Drive… (bản cũ chỉ có quyền hạn chế).",
            en: "Import again: Import photos… › From Google Drive… (older versions had limited access).")
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

    /// The provider did not say who signed in (its account call failed), so nothing can be compared yet.
    public static func accountUnknown(expected: String?, signedIn: String?) -> Bool {
        let known = { (value: String?) in !(value?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) }
        return known(expected) && !known(signedIn)
    }

    /// Shown when an import would start with no way to tell which account it reads from.
    public static var accountUnverifiedStartNotice: String {
        tr(vi: "Chưa kiểm tra được tài khoản đang đăng nhập, nên chưa nhập. Hãy thử lại.", en: "The signed-in account could not be checked, so nothing was imported. Try again.")
    }

    /// Shown while a browser sign-in is open.
    public static var waitingForBrowser: String { tr(vi: "Đang chờ đăng nhập trong trình duyệt…", en: "Waiting for sign-in in the browser…") }

    public static var accountUnverifiedNotice: String {
        tr(vi: "Chưa kiểm tra được tài khoản vừa đăng nhập. Hãy thử lại.", en: "The signed-in account could not be checked. Try again.")
    }

    /// Case-insensitive. An import with no recorded account cannot be checked, so nothing matches it.
    public static func isSameAccount(expected: String?, signedIn: String?) -> Bool {
        guard let expected = expected?.trimmingCharacters(in: .whitespaces), !expected.isEmpty else { return false }
        guard let signedIn = signedIn?.trimmingCharacters(in: .whitespaces), !signedIn.isEmpty else { return false }
        return expected.caseInsensitiveCompare(signedIn) == .orderedSame
    }
}

/// Keychain items that belong to cloud imports and the Dropbox account.
public enum CloudImportKeychain {
    /// Every item Factory Reset removes, found by listing the Keychain, so a grant whose import row is
    /// missing or unreadable is removed too.
    public static func accountsToDelete(stored: [String]) -> [String] { stored.filter(CloudTokenAccount.isCloudItem) }

    /// Lets go of the sign-in of each import in `ids` that still has one: deletes its `import-<id>` item, and only
    /// when that worked drops the adapter. Nothing else in the Keychain is touched; ids without a grant are skipped,
    /// so running it again changes nothing.
    public static func release(
        ids: [SourceID], hasGrant: (SourceID) -> Bool, deleteGrant: (String) -> Bool, dropAdapter: (SourceID) async -> Void
    ) async -> (released: Int, failed: Int) {
        var released = 0, failed = 0
        for id in ids where hasGrant(id) {
            if deleteGrant(CloudTokenAccount.importGrant(id)) {
                await dropAdapter(id)
                released += 1
            } else {
                failed += 1
            }
        }
        return (released, failed)
    }

    /// Open cloud imports that have no stored sign-in. Finished imports let their sign-in go on purpose.
    public static func missingToken(_ rows: [SourceRecord], hasGrant: (SourceID) -> Bool) -> Int {
        rows.filter { ($0.kind == .googleDrive || $0.kind == .dropbox) && $0.status.isOpen && !hasGrant($0.id) }.count
    }

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
