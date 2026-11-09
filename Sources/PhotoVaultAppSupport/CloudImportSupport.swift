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

    public static func needsSignIn(_ item: ImportSnapshot) -> Bool {
        (item.kind == .googleDrive || item.kind == .dropbox) && item.status == .offline && item.statusReason == "signInRequired"
    }
}

/// Keychain items that belong to cloud imports and the Dropbox account.
public enum CloudImportKeychain {
    public static let dropboxAccount = "dropbox-account"

    public static func importAccount(_ id: SourceID) -> String { "import-\(id.rawValue)" }

    /// Every item Factory Reset removes: one grant per cloud import and the Dropbox account token.
    public static func accountsToDelete(imports: [SourceRecord]) -> [String] {
        imports.filter { $0.kind == .googleDrive || $0.kind == .dropbox }.map { importAccount($0.id) } + [dropboxAccount]
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
