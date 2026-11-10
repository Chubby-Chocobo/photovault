import Foundation
import PhotoVaultCore
@testable import PhotoVaultEngine
import Testing
@testable import PhotoVaultAppSupport

@Suite struct CloudImportSupportTests {
    func vi<T>(_ body: () -> T) -> T { L10n.$override.withValue(.vi, operation: body) }
    func en<T>(_ body: () -> T) -> T { L10n.$override.withValue(.en, operation: body) }

    func snapshot(kind: SourceKind, status: SourceStatus, found: Int = 0, reason: String? = nil) -> ImportSnapshot {
        ImportSnapshot(id: .folder(), kind: kind, statusReason: reason, displayName: "X", status: status,
                       createdAt: Date(timeIntervalSince1970: 1_800_000_000), found: found)
    }

    func record(_ kind: SourceKind, bookmark: Data? = nil) -> SourceRecord {
        SourceRecord(id: .folder(), kind: kind, mode: .oneTime, displayName: "n", config: SourceConfig(bookmark: bookmark),
                     status: .scanning, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func providerLabels() {
        vi {
            #expect(CloudImportText.providerLabel(kind: .localFolder, account: nil) == "Thư mục trên Mac")
            #expect(CloudImportText.providerLabel(kind: .googleDrive, account: "a@b.c") == "Google Drive · a@b.c")
            #expect(CloudImportText.providerLabel(kind: .dropbox, account: "a@b.c") == "Dropbox · a@b.c")
            #expect(CloudImportText.providerLabel(kind: .dropbox, account: " ") == "Dropbox")
            #expect(CloudImportText.providerLabel(kind: .googleDrive, account: nil) == "Google Drive")
        }
    }

    @Test func googleDisplayName() {
        vi {
            #expect(CloudImportText.googleDisplayName(singleFolderName: "Đà Lạt", pickedCount: 1) == "Đà Lạt")
            #expect(CloudImportText.googleDisplayName(singleFolderName: nil, pickedCount: 1) == "1 mục từ Google Drive")
            #expect(CloudImportText.googleDisplayName(singleFolderName: "Đà Lạt", pickedCount: 3) == "3 mục từ Google Drive")
            #expect(CloudImportText.googleDisplayName(singleFolderName: "  ", pickedCount: 1) == "1 mục từ Google Drive")
        }
        en { #expect(CloudImportText.googleDisplayName(singleFolderName: nil, pickedCount: 2) == "2 items from Google Drive") }
    }

    @Test func dropboxDisplayName() {
        #expect(CloudImportText.dropboxDisplayName(path: "/Photos/2024") == "2024")
        vi { #expect(CloudImportText.dropboxDisplayName(path: "") == "Toàn bộ Dropbox") }
    }

    @Test func emptyImportNoticeForAnyFinishedImportThatFoundNothing() {
        for kind in [SourceKind.googleDrive, .dropbox, .localFolder] {
            #expect(CloudImportText.emptyImportNotice(snapshot(kind: kind, status: .completed)) != nil)
            #expect(CloudImportText.emptyImportNotice(snapshot(kind: kind, status: .completed, found: 3)) == nil)
            #expect(CloudImportText.emptyImportNotice(snapshot(kind: kind, status: .importing)) == nil)
            #expect(CloudImportText.emptyImportNotice(snapshot(kind: kind, status: .cancelled)) == nil)
        }
    }

    @Test func emptyImportNoticeTextAndGoogleHint() {
        vi {
            let box = CloudImportText.emptyImportNotice(snapshot(kind: .dropbox, status: .completed))
            #expect(box == "Thư mục này không có ảnh hay video nào mà app đọc được.")
            let drive = CloudImportText.emptyImportNotice(snapshot(kind: .googleDrive, status: .completed)) ?? ""
            #expect(drive.hasPrefix("Thư mục này không có ảnh hay video nào mà app đọc được."))
            #expect(drive.contains("đăng nhập lại") && drive.contains("chọn lại thư mục"))
        }
        en {
            #expect(CloudImportText.emptyImportNotice(snapshot(kind: .localFolder, status: .completed)) == "This folder had no photos or videos the app could read.")
            #expect((CloudImportText.emptyImportNotice(snapshot(kind: .googleDrive, status: .completed)) ?? "").contains("sign in again and pick the folder again"))
        }
    }

    @Test func signInRequiredForCloudImportsHeldOrFinished() {
        #expect(CloudImportText.needsSignIn(snapshot(kind: .dropbox, status: .offline, reason: "signInRequired")))
        #expect(CloudImportText.needsSignIn(snapshot(kind: .googleDrive, status: .offline, reason: "signInRequired")))
        #expect(CloudImportText.needsSignIn(snapshot(kind: .googleDrive, status: .completed, reason: "signInRequired")))
        #expect(!CloudImportText.needsSignIn(snapshot(kind: .dropbox, status: .offline, reason: "unavailable")))
        #expect(!CloudImportText.needsSignIn(snapshot(kind: .dropbox, status: .completed)))
        #expect(!CloudImportText.needsSignIn(snapshot(kind: .localFolder, status: .offline, reason: "signInRequired")))
    }

    @Test func keychainCleanupTakesEveryCloudItemIndependentOfDatabaseRows() {
        let stored = ["refresh-token", "import-folder-1", "dropbox-account", "import-folder-2", "other"]
        #expect(CloudImportKeychain.accountsToDelete(stored: stored) == ["import-folder-1", "dropbox-account", "import-folder-2"])
        #expect(CloudImportKeychain.accountsToDelete(stored: []).isEmpty)
    }

    @Test func mergingPicksKeepsOrderAndDropsRepeats() {
        #expect(CloudImportText.mergedPicks(existing: ["a", "b"], picked: ["b", "c", "a", "d"]) == ["a", "b", "c", "d"])
        #expect(CloudImportText.mergedPicks(existing: [], picked: ["x"]) == ["x"])
        #expect(CloudImportText.mergedPicks(existing: ["x"], picked: []) == ["x"])
    }

    @Test func accountComparisonIgnoresCase() {
        #expect(CloudImportText.isSameAccount(expected: "Me@Example.com", signedIn: "me@example.COM"))
        #expect(!CloudImportText.isSameAccount(expected: "me@example.com", signedIn: "you@example.com"))
        #expect(!CloudImportText.isSameAccount(expected: "me@example.com", signedIn: nil))
        #expect(CloudImportText.accountUnknown(expected: "me@example.com", signedIn: nil))
        #expect(!CloudImportText.accountUnknown(expected: "me@example.com", signedIn: "you@example.com"))
        #expect(!CloudImportText.accountUnknown(expected: nil, signedIn: nil))
        #expect(!CloudImportText.isSameAccount(expected: nil, signedIn: "any@example.com"), "an import with no recorded account matches nothing")
        #expect(!CloudImportText.isSameAccount(expected: " ", signedIn: "any@example.com"))
        vi { #expect(CloudImportText.wrongAccountNotice(expected: "me@example.com") == "Hãy đăng nhập đúng tài khoản me@example.com") }
        en { #expect(CloudImportText.wrongAccountNotice(expected: "me@example.com") == "Sign in with the account me@example.com") }
    }

    @Test func sidecarNamesDoNotDependOnTheLanguage() {
        for run in [vi, en] as [((() -> [String]) -> [String])] {
            let names = run {
                [CloudImportText.googleSidecarName(singleFolderName: "Đà Lạt", pickedCount: 1),
                 CloudImportText.googleSidecarName(singleFolderName: "Đà Lạt", pickedCount: 3),
                 CloudImportText.googleSidecarName(singleFolderName: nil, pickedCount: 1),
                 CloudImportText.dropboxSidecarName(path: "/Photos/2024"),
                 CloudImportText.dropboxSidecarName(path: "")]
            }
            #expect(names == ["Đà Lạt", "Google Drive", "Google Drive", "2024", "Dropbox"])
        }
    }

    @Test func aFileWaitingForRoomIsExplained() {
        let waiting = snapshot(kind: .dropbox, status: .scanning, reason: "diskFull")
        #expect(ImportProgressText.waitsForDisk(waiting))
        #expect(!ImportProgressText.waitsForDisk(snapshot(kind: .dropbox, status: .scanning)))
        vi { #expect(ImportProgressText.statusLabel(waiting).contains("file") && ImportProgressText.statusLabel(waiting).contains("ổ Mac")) }
        en { #expect(ImportProgressText.statusLabel(waiting).contains("free space on the Mac disk")) }
    }

    @Test func registrationKeepsCloudRowsOnlyWithGrant() {
        let drive = record(.googleDrive), box = record(.dropbox)
        let withBookmark = record(.localFolder, bookmark: Data([1])), without = record(.localFolder)
        let kept = CloudImportKeychain.registrable([drive, box, withBookmark, without]) { $0 == box.id }
        #expect(kept.map(\.id) == [box.id, withBookmark.id])
    }

    @Test func cloudStatusLabels() {
        vi {
            #expect(ImportProgressText.statusLabel(snapshot(kind: .dropbox, status: .offline, reason: "signInRequired")) == "Cần đăng nhập lại")
            #expect(ImportProgressText.statusLabel(snapshot(kind: .dropbox, status: .offline)).hasPrefix("Chưa kết nối được"))
            #expect(ImportProgressText.statusLabel(snapshot(kind: .localFolder, status: .offline)).hasPrefix("Thư mục không truy cập được"))
            #expect(ImportProgressText.statusLabel(snapshot(kind: .googleDrive, status: .importing)) == "Đang upload…")
        }
    }
}
