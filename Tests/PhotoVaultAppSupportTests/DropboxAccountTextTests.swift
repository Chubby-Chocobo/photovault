import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultAppSupport

struct DropboxAccountTextTests {
    private func vi<T>(_ body: () -> T) -> T { L10n.$override.withValue(.vi, operation: body) }
    private func en<T>(_ body: () -> T) -> T { L10n.$override.withValue(.en, operation: body) }

    @Test func settingsLineSaysWhoIsSignedIn() {
        #expect(vi { DropboxAccountText.line(signedIn: true, email: "ten@example.com") } == "Dropbox: đã đăng nhập bằng ten@example.com")
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

    // MARK: Lazy e-mail

    private final class Calls: @unchecked Sendable {
        var saved: [String] = []
        var signedIn = true
        var tokenPresent = true
        var storedEmail: String?
    }

    @MainActor private func resolve(_ calls: Calls, fetch: @escaping () async throws -> String) async -> String? {
        await DropboxEmailRefresh.resolve(
            signedIn: { calls.signedIn }, tokenPresent: { calls.tokenPresent }, stored: { calls.storedEmail },
            fetch: fetch, save: { calls.saved.append($0); calls.storedEmail = $0 })
    }

    @Test @MainActor func aStoredEmailIsUsedWithoutAskingDropbox() async {
        let calls = Calls()
        calls.storedEmail = "kept@example.com"
        let shown = await resolve(calls) { Issue.record("must not fetch"); return "x" }
        #expect(shown == "kept@example.com" && calls.saved.isEmpty)
    }

    @Test @MainActor func anOlderTokenIsAskedOnceAndTheAnswerIsSaved() async {
        let calls = Calls()
        let shown = await resolve(calls) { "ten@example.com" }
        #expect(shown == "ten@example.com" && calls.saved == ["ten@example.com"])
    }

    @Test @MainActor func aFailedFetchShowsNothingAndSavesNothing() async {
        let calls = Calls()
        let shown = await resolve(calls) { throw SourceError.unavailable }
        #expect(shown == nil && calls.saved.isEmpty)
    }

    @Test @MainActor func aSignOutDuringTheFetchDoesNotBringTheEmailBack() async {
        let calls = Calls()
        let shown = await resolve(calls) { calls.signedIn = false; calls.tokenPresent = false; return "ten@example.com" }
        #expect(shown == nil && calls.saved.isEmpty)
    }

    @Test @MainActor func aSignInDuringTheFetchKeepsTheNewAccountsEmail() async {
        let calls = Calls()
        let shown = await resolve(calls) { calls.storedEmail = "new@example.com"; return "old@example.com" }
        #expect(shown == "new@example.com" && calls.saved.isEmpty)
    }
}
