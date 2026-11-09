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

    @Test func emptyGoogleHintOnlyForFinishedEmptyDriveImport() {
        #expect(CloudImportText.emptyGoogleHint(snapshot(kind: .googleDrive, status: .completed)) != nil)
        #expect(CloudImportText.emptyGoogleHint(snapshot(kind: .googleDrive, status: .completed, found: 3)) == nil)
        #expect(CloudImportText.emptyGoogleHint(snapshot(kind: .googleDrive, status: .importing)) == nil)
        #expect(CloudImportText.emptyGoogleHint(snapshot(kind: .dropbox, status: .completed)) == nil)
        #expect(CloudImportText.emptyGoogleHint(snapshot(kind: .localFolder, status: .completed)) == nil)
    }

    @Test func signInRequiredOnlyForOfflineCloudImports() {
        #expect(CloudImportText.needsSignIn(snapshot(kind: .dropbox, status: .offline, reason: "signInRequired")))
        #expect(CloudImportText.needsSignIn(snapshot(kind: .googleDrive, status: .offline, reason: "signInRequired")))
        #expect(!CloudImportText.needsSignIn(snapshot(kind: .dropbox, status: .offline, reason: "unavailable")))
        #expect(!CloudImportText.needsSignIn(snapshot(kind: .localFolder, status: .offline, reason: "signInRequired")))
        #expect(!CloudImportText.needsSignIn(snapshot(kind: .dropbox, status: .importing, reason: "signInRequired")))
    }

    @Test func keychainCleanupCoversCloudGrantsAndDropboxAccount() {
        let drive = record(.googleDrive), box = record(.dropbox), folder = record(.localFolder, bookmark: Data([1]))
        let accounts = CloudImportKeychain.accountsToDelete(imports: [drive, box, folder])
        #expect(accounts == ["import-\(drive.id.rawValue)", "import-\(box.id.rawValue)", "dropbox-account"])
        #expect(CloudImportKeychain.accountsToDelete(imports: []) == ["dropbox-account"])
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
