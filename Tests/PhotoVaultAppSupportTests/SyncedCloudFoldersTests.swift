import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultAppSupport

@Suite struct SyncedCloudFoldersTests {
    let home = URL(fileURLWithPath: "/Users/me")
    let storage = "/Users/me/Library/CloudStorage"

    /// Fake file-system listing: directory path -> names, nil when the directory cannot be listed.
    func lister(_ tree: [String: [String]]) -> (URL) -> [String]? { { tree[$0.path] } }
    func vi<T>(_ body: () -> T) -> T { L10n.$override.withValue(.vi, operation: body) }
    func en<T>(_ body: () -> T) -> T { L10n.$override.withValue(.en, operation: body) }

    // MARK: Detection

    @Test func sandboxedListingFailsButAppIsInstalled() {
        let found = SyncedCloudFolders.detect(.googleDrive, home: home, appInstalled: { $0 == "com.google.drivefs" }, list: lister([:]))
        #expect(found.isAvailable)
        #expect(found.startDirectory.path == storage)
    }

    @Test func notInstalledAndNothingListed() {
        let found = SyncedCloudFolders.detect(.dropbox, home: home, appInstalled: { _ in false }, list: lister([storage: [".DS_Store", "Box-Box"]]))
        #expect(!found.isAvailable)
    }

    @Test func oneGoogleAccountStartsInsideIt() {
        let found = SyncedCloudFolders.detect(.googleDrive, home: home, appInstalled: { _ in true }, list: lister([storage: ["GoogleDrive-a@b.c", "Dropbox"]]))
        #expect(found.startDirectory.path == storage + "/GoogleDrive-a@b.c")
    }

    @Test func severalGoogleAccountsStartAtCloudStorage() {
        let found = SyncedCloudFolders.detect(.googleDrive, home: home, appInstalled: { _ in false },
                                              list: lister([storage: ["GoogleDrive-a@b.c", "GoogleDrive-x@y.z"]]))
        #expect(found.isAvailable)
        #expect(found.startDirectory.path == storage)
    }

    @Test func listedFolderMakesItAvailableWithoutTheApp() {
        let found = SyncedCloudFolders.detect(.googleDrive, home: home, appInstalled: { _ in false }, list: lister([storage: ["GoogleDrive-a@b.c"]]))
        #expect(found.isAvailable)
    }

    @Test func dropboxVariantsAndLegacyFolder() {
        for name in ["Dropbox", "Dropbox-Personal", "Dropbox (Team)"] {
            let found = SyncedCloudFolders.detect(.dropbox, home: home, appInstalled: { _ in false }, list: lister([storage: [name]]))
            #expect(found.isAvailable, "\(name)")
            #expect(found.startDirectory.path == storage + "/" + name)
        }
        let legacy = SyncedCloudFolders.detect(.dropbox, home: home, appInstalled: { _ in false }, list: lister([home.path: ["Dropbox", "Documents"]]))
        #expect(legacy.isAvailable)
        #expect(legacy.startDirectory.path == "/Users/me/Dropbox")
    }

    // MARK: Provider and account of a picked folder

    @Test func providerAndAccountFromPickedPath() {
        let drive = storage + "/GoogleDrive-a@b.c/My Drive/Trip"
        #expect(SyncedCloudFolders.provider(ofPath: drive, home: home) == .googleDrive)
        #expect(SyncedCloudFolders.account(ofPath: drive) == "a@b.c")
        #expect(SyncedCloudFolders.provider(ofPath: storage + "/Dropbox/Photos", home: home) == .dropbox)
        #expect(SyncedCloudFolders.provider(ofPath: "/Users/me/Dropbox/Photos", home: home) == .dropbox)
        #expect(SyncedCloudFolders.account(ofPath: storage + "/Dropbox/Photos") == nil)
        #expect(SyncedCloudFolders.provider(ofPath: "/Users/me/Pictures", home: home) == nil)
        // A folder merely named like a provider elsewhere is not synced.
        #expect(SyncedCloudFolders.provider(ofPath: "/Volumes/Disk/GoogleDrive-a@b.c/x", home: home) == nil)
        #expect(SyncedCloudFolders.provider(ofPath: "/Users/me/Documents/Dropbox/x", home: home) == nil)
    }

    @Test func displayPathHidesTheCloudStoragePrefixAndAccount() {
        #expect(SyncedCloudFolders.displayPath(storage + "/GoogleDrive-a@b.c/My Drive/Trip", home: home) == "Google Drive/My Drive/Trip")
        #expect(SyncedCloudFolders.displayPath(storage + "/GoogleDrive-a@b.c", home: home) == "Google Drive")
        #expect(SyncedCloudFolders.displayPath(storage + "/Dropbox/Photos", home: home) == "Dropbox/Photos")
        #expect(SyncedCloudFolders.displayPath(storage + "/Dropbox-Personal", home: home) == "Dropbox")
        #expect(SyncedCloudFolders.displayPath("/Users/me/Dropbox/Photos", home: home) == "Dropbox/Photos")
        #expect(SyncedCloudFolders.displayPath("/Users/me/Pictures", home: home) == nil)
    }

    // MARK: Text

    @Test func providerLabel() {
        vi {
            #expect(SyncedCloudText.label(.googleDrive, account: "a@b.c") == "Google Drive (trên máy này) · a@b.c")
            #expect(SyncedCloudText.label(.dropbox, account: nil) == "Dropbox (trên máy này)")
            #expect(SyncedCloudText.label(.dropbox, account: "  ") == "Dropbox (trên máy này)")
        }
        en { #expect(SyncedCloudText.label(.googleDrive, account: nil) == "Google Drive (on this Mac)") }
    }

    @Test func importRowLabelUsesTheSyncedProvider() {
        vi {
            #expect(CloudImportText.providerLabel(kind: .localFolder, account: "a@b.c", syncedProvider: .googleDrive) == "Google Drive (trên máy này) · a@b.c")
            #expect(CloudImportText.providerLabel(kind: .localFolder, account: nil, syncedProvider: nil) == "Thư mục trên Mac")
        }
    }

    @Test func unverifiedWarningNamesTheScreenAndTheWayThrough() {
        vi {
            let text = SyncedCloudText.googleUnverifiedWarning
            #expect(text.contains("chưa xác minh"))
            #expect(text.contains("Nâng cao"))
            #expect(text.contains("Đi tới PhotoVault"))
        }
        en {
            let text = SyncedCloudText.googleUnverifiedWarning
            #expect(text.contains("hasn’t verified"))
            #expect(text.contains("Advanced"))
            #expect(text.contains("PhotoVault"))
        }
    }

    @Test func panelTitles() {
        vi { #expect(SyncedCloudText.panelTitle(.googleDrive) == "Chọn thư mục Google Drive (đồng bộ trên máy này)") }
        vi { #expect(SyncedCloudText.panelTitle(.dropbox) == "Chọn thư mục Dropbox (đồng bộ trên máy này)") }
    }
}
