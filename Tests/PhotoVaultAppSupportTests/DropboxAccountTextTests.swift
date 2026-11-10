import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultAppSupport

struct DropboxAccountTextTests {
    private func vi<T>(_ body: () -> T) -> T { L10n.$override.withValue(.vi, operation: body) }
    private func en<T>(_ body: () -> T) -> T { L10n.$override.withValue(.en, operation: body) }

    @Test func settingsLineSaysWhoIsSignedIn() {
        #expect(vi { DropboxAccountText.line(signedIn: true, email: "ten@example.com") } == "Dropbox: đã đăng nhập ten@example.com")
        #expect(en { DropboxAccountText.line(signedIn: true, email: "ten@example.com") } == "Dropbox: signed in as ten@example.com")
    }

    @Test func aTokenFromAnOlderVersionHasNoEmailYet() {
        #expect(vi { DropboxAccountText.line(signedIn: true, email: nil) } == "Dropbox: đã đăng nhập")
        #expect(vi { DropboxAccountText.line(signedIn: true, email: "  ") } == "Dropbox: đã đăng nhập")
        #expect(en { DropboxAccountText.line(signedIn: true, email: nil) } == "Dropbox: signed in")
    }

    @Test func noTokenMeansNotSignedInWhateverEmailIsLeft() {
        #expect(vi { DropboxAccountText.line(signedIn: false, email: "ten@example.com") } == "Dropbox: chưa đăng nhập")
        #expect(en { DropboxAccountText.line(signedIn: false, email: nil) } == "Dropbox: not signed in")
    }
}
