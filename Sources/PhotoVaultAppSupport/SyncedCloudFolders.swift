import Foundation
import PhotoVaultCore

/// Finds the folders Google Drive for desktop and the Dropbox app keep on this Mac, so an import can read
/// them without signing in to the provider. Pure: the app passes in the real file-system calls.
public enum SyncedCloudFolders {
    public struct Detection: Equatable, Sendable {
        /// The provider's desktop app is installed, or its folder was seen.
        public var isAvailable: Bool
        /// Where the folder chooser opens.
        public var startDirectory: URL
    }

    /// Bundle identifier of the provider's desktop app.
    public static func bundleID(_ provider: SyncedCloudProvider) -> String {
        switch provider {
        case .googleDrive: "com.google.drivefs"
        case .dropbox: "com.getdropbox.dropbox"
        }
    }

    /// `~/Library/CloudStorage` under the real home (the sandbox's own home is the container).
    public static func cloudStorage(home: URL) -> URL { home.appendingPathComponent("Library/CloudStorage") }

    /// `list` returns the names inside a directory, or nil when it cannot be listed. The sandbox refuses to
    /// list `~/Library/CloudStorage`, so the installed app is the main signal and a listing only refines it.
    public static func detect(_ provider: SyncedCloudProvider, home: URL, appInstalled: (String) -> Bool, list: (URL) -> [String]?) -> Detection {
        let storage = cloudStorage(home: home)
        var roots = (list(storage) ?? []).filter { isRootName($0, of: provider) }.map { storage.appendingPathComponent($0) }
        if provider == .dropbox, (list(home) ?? []).contains("Dropbox") { roots.append(home.appendingPathComponent("Dropbox")) }
        let available = appInstalled(bundleID(provider)) || !roots.isEmpty
        return Detection(isAvailable: available, startDirectory: roots.count == 1 ? roots[0] : storage)
    }

    /// The provider whose synced folder holds `path`, from the folder names on the way down; nil elsewhere.
    public static func provider(ofPath path: String, home: URL) -> SyncedCloudProvider? {
        let storage = cloudStorage(home: home).path + "/"
        if path.hasPrefix(storage), let first = path.dropFirst(storage.count).split(separator: "/").first {
            return SyncedCloudProvider.allCases.first { isRootName(String(first), of: $0) }
        }
        let legacy = home.appendingPathComponent("Dropbox").path
        return path == legacy || path.hasPrefix(legacy + "/") ? .dropbox : nil
    }

    /// The path as the import row shows it: the provider's name instead of the `~/Library/CloudStorage/<root>`
    /// prefix (the account is in the row's label already). nil when `path` is not in a synced folder.
    public static func displayPath(_ path: String, home: URL) -> String? {
        guard let provider = provider(ofPath: path, home: home) else { return nil }
        let storage = cloudStorage(home: home).path + "/"
        let legacy = home.appendingPathComponent("Dropbox").path
        let tail: Substring
        if path.hasPrefix(storage) {
            let parts = path.dropFirst(storage.count).split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            tail = parts.count > 1 ? parts[1] : ""
        } else {
            tail = path.dropFirst(legacy.count).drop(while: { $0 == "/" })
        }
        let name = provider == .googleDrive ? "Google Drive" : "Dropbox"
        return tail.isEmpty ? name : "\(name)/\(tail)"
    }

    /// The Google account in the `GoogleDrive-<email>` folder directly under `~/Library/CloudStorage`; nil for
    /// anything else, so a folder the owner named like a root cannot pass for an account.
    public static func account(ofPath path: String, home: URL) -> String? {
        let storage = cloudStorage(home: home).path + "/"
        guard path.hasPrefix(storage), let root = path.dropFirst(storage.count).split(separator: "/").first,
              root.hasPrefix("GoogleDrive-") else { return nil }
        let email = root.dropFirst("GoogleDrive-".count)
        return email.isEmpty ? nil : String(email)
    }

    static func isRootName(_ name: String, of provider: SyncedCloudProvider) -> Bool {
        switch provider {
        case .googleDrive: name.hasPrefix("GoogleDrive-")
        case .dropbox: name == "Dropbox" || name.hasPrefix("Dropbox-") || name.hasPrefix("Dropbox (")
        }
    }
}

/// Interface text for imports from a synced cloud folder.
public enum SyncedCloudText {
    /// Shown on the import row: "Google Drive (trên máy này) · email".
    public static func label(_ provider: SyncedCloudProvider, account: String?) -> String {
        let name = provider == .googleDrive ? "Google Drive" : "Dropbox"
        let base = "\(name) " + tr(vi: "(trên máy này)", en: "(on this Mac)")
        guard let account = account?.trimmingCharacters(in: .whitespaces), !account.isEmpty else { return base }
        return "\(base) · \(account)"
    }

    public static func panelTitle(_ provider: SyncedCloudProvider) -> String {
        switch provider {
        case .googleDrive: tr(vi: "Chọn thư mục Google Drive (đồng bộ trên máy này)", en: "Choose a Google Drive folder (synced on this Mac)")
        case .dropbox: tr(vi: "Chọn thư mục Dropbox (đồng bộ trên máy này)", en: "Choose a Dropbox folder (synced on this Mac)")
        }
    }

    public static var useBrowserInstead: String { tr(vi: "Dùng trình duyệt thay thế", en: "Use the browser instead") }

    /// Said before the browser flow, because Google shows its "not verified" screen for the restricted read scope.
    public static var googleUnverifiedWarning: String {
        tr(vi: "Google sẽ báo “chưa xác minh” vì app dùng quyền đọc Drive; đây là app của bạn — chọn Nâng cao › Đi tới PhotoVault.",
           en: "Google will say it “hasn’t verified this app” because the app uses the Drive read permission; this is your own app — choose Advanced › Go to PhotoVault.")
    }

    public static var avoidWarningHint: String {
        tr(vi: "Muốn tránh màn hình này: cài Google Drive cho máy tính, PhotoVault sẽ đọc thư mục đồng bộ trên máy, không cần đăng nhập.",
           en: "To avoid this screen: install Google Drive for desktop; PhotoVault then reads the synced folder on this Mac with no sign-in.")
    }

    public static let googleDriveDesktopURL = URL(string: "https://www.google.com/drive/download/")!
}
