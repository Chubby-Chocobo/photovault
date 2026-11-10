import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultAppSupport

@Suite struct ImportMenuChoicesTests {
    func vi<T>(_ body: () -> T) -> T { L10n.$override.withValue(.vi, operation: body) }
    func en<T>(_ body: () -> T) -> T { L10n.$override.withValue(.en, operation: body) }

    @Test(arguments: SyncedCloudProvider.allCases)
    func bothWaysAreTwoNamedItems(provider: SyncedCloudProvider) {
        vi {
            let items = ImportMenuChoices.items(provider, appPresent: true, browserConfigured: true)
            let name = provider == .googleDrive ? "Google Drive" : "Dropbox"
            #expect(items.map(\.action) == [.syncedFolder, .browser])
            #expect(items.map(\.title) == ["\(name) trên máy này…", "\(name) qua trình duyệt…"])
            #expect(items.allSatisfy { $0.isEnabled })
            #expect(items.allSatisfy { !$0.help.isEmpty })
        }
    }

    @Test func helpSaysWhatEachWayIsFor() {
        vi {
            let items = ImportMenuChoices.items(.googleDrive, appPresent: true, browserConfigured: true)
            #expect(items[0].help == "Không cần đăng nhập, không có cảnh báo của Google")
            #expect(items[1].help == "Dùng được với tài khoản Google chưa đồng bộ trên máy này")
            let dropbox = ImportMenuChoices.items(.dropbox, appPresent: true, browserConfigured: true)
            #expect(dropbox[0].help == "Không cần đăng nhập")
            #expect(dropbox[1].help == "Dùng được với tài khoản Dropbox chưa đồng bộ trên máy này")
        }
    }

    @Test(arguments: SyncedCloudProvider.allCases)
    func onlyTheDesktopAppIsOneItemThatOpensTheFolderChooser(provider: SyncedCloudProvider) {
        vi {
            let items = ImportMenuChoices.items(provider, appPresent: true, browserConfigured: false)
            #expect(items.count == 1 && items[0].action == .syncedFolder && items[0].isEnabled)
            #expect(items[0].title == (provider == .googleDrive ? "Từ Google Drive…" : "Từ Dropbox…"))
        }
    }

    @Test(arguments: SyncedCloudProvider.allCases)
    func onlyTheBuildKeyIsOneItemThatOpensTheBrowser(provider: SyncedCloudProvider) {
        vi {
            let items = ImportMenuChoices.items(provider, appPresent: false, browserConfigured: true)
            #expect(items.count == 1 && items[0].action == .browser && items[0].isEnabled)
            #expect(items[0].title == (provider == .googleDrive ? "Từ Google Drive…" : "Từ Dropbox…"))
        }
    }

    @Test(arguments: SyncedCloudProvider.allCases)
    func neitherIsOneDisabledItemThatSaysWhy(provider: SyncedCloudProvider) {
        vi {
            let items = ImportMenuChoices.items(provider, appPresent: false, browserConfigured: false)
            #expect(items.count == 1 && !items[0].isEnabled)
            #expect(items[0].help.contains(provider == .googleDrive ? "Google" : "Dropbox"))
        }
        en {
            let items = ImportMenuChoices.items(.dropbox, appPresent: false, browserConfigured: false)
            #expect(items[0].title == "From Dropbox…")
        }
    }

    @Test func titlesAreTranslated() {
        en {
            let items = ImportMenuChoices.items(.googleDrive, appPresent: true, browserConfigured: true)
            #expect(items.map(\.title) == ["Google Drive on this Mac…", "Google Drive in the browser…"])
        }
    }
}
