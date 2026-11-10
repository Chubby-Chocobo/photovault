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
            // The reason is in the title itself: a disabled menu item may not show its tooltip.
            #expect(items[0].title == (provider == .googleDrive ? "Từ Google Drive… (cần cài Google Drive cho máy tính)" : "Từ Dropbox… (cần cài ứng dụng Dropbox)"))
        }
        en {
            let items = ImportMenuChoices.items(.dropbox, appPresent: false, browserConfigured: false)
            #expect(items[0].title == "From Dropbox… (install the Dropbox app)")
            #expect(ImportMenuChoices.items(.googleDrive, appPresent: false, browserConfigured: false)[0].title == "From Google Drive… (install Google Drive for desktop)")
        }
    }

    @Test func titlesAreTranslated() {
        en {
            let items = ImportMenuChoices.items(.googleDrive, appPresent: true, browserConfigured: true)
            #expect(items.map(\.title) == ["Google Drive on this Mac…", "Google Drive in the browser…"])
        }
    }

    // MARK: Dropbox sign-in on its own item

    @Test func signedInShowsTheAccountOnTheBrowserItemAndAddsSignOut() {
        vi {
            let items = ImportMenuChoices.items(.dropbox, appPresent: true, browserConfigured: true, dropbox: .signedIn(email: "ten@x.com"))
            #expect(items.map(\.action) == [.syncedFolder, .browser, .signOut])
            #expect(items[1].title == "Dropbox qua trình duyệt… · ten@x.com")
            #expect(items[2].title == "Đăng xuất Dropbox (ten@x.com)")
            #expect(items[2].help == "Các lần nhập đang có vẫn giữ quyền đọc riêng của chúng.")
            #expect(items[0].title == "Dropbox trên máy này…")
        }
    }

    @Test func signedOutSaysSoInTheHelpOfTheBrowserItem() {
        vi {
            let items = ImportMenuChoices.items(.dropbox, appPresent: true, browserConfigured: true, dropbox: .signedOut)
            #expect(items.map(\.action) == [.syncedFolder, .browser])
            #expect(items[1].title == "Dropbox qua trình duyệt…")
            #expect(items[1].help == "Chưa đăng nhập — sẽ mở trình duyệt để đăng nhập")
        }
    }

    @Test func theSingleBrowserItemCarriesTheStateToo() {
        vi {
            let out = ImportMenuChoices.items(.dropbox, appPresent: false, browserConfigured: true, dropbox: .signedOut)
            #expect(out.map(\.title) == ["Từ Dropbox…"] && out[0].help == "Chưa đăng nhập — sẽ mở trình duyệt để đăng nhập")
            let signedIn = ImportMenuChoices.items(.dropbox, appPresent: false, browserConfigured: true, dropbox: .signedIn(email: "ten@x.com"))
            #expect(signedIn.map(\.title) == ["Từ Dropbox… · ten@x.com", "Đăng xuất Dropbox (ten@x.com)"])
        }
    }

    @Test func aSignedInAccountWithoutAnEmailStillOffersSignOut() {
        vi {
            let items = ImportMenuChoices.items(.dropbox, appPresent: false, browserConfigured: true, dropbox: .signedIn(email: " "))
            #expect(items.map(\.title) == ["Từ Dropbox…", "Đăng xuất Dropbox"])
        }
    }

    @Test func theSyncedOnlyItemIsUnaffectedByTheSignIn() {
        vi {
            let items = ImportMenuChoices.items(.dropbox, appPresent: true, browserConfigured: false, dropbox: .signedOut)
            #expect(items.map(\.action) == [.syncedFolder] && items[0].help == "")
        }
    }

    @Test func googleNeverShowsSignInState() {
        vi {
            let items = ImportMenuChoices.items(.googleDrive, appPresent: true, browserConfigured: true, dropbox: .signedIn(email: "ten@x.com"))
            #expect(items.map(\.action) == [.syncedFolder, .browser])
            #expect(!items[1].title.contains("ten@x.com"))
        }
    }

    @Test func englishTexts() {
        en {
            let items = ImportMenuChoices.items(.dropbox, appPresent: true, browserConfigured: true, dropbox: .signedIn(email: "ten@x.com"))
            #expect(items[1].title == "Dropbox in the browser… · ten@x.com")
            #expect(items[2].title == "Sign out of Dropbox (ten@x.com)")
            let out = ImportMenuChoices.items(.dropbox, appPresent: false, browserConfigured: true, dropbox: .signedOut)
            #expect(out[0].help == "Not signed in — opens the browser to sign in")
        }
    }
}
