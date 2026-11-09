import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultDropbox

@Suite struct DropboxTokenAuthorizerTests {
    private func make(_ keychain: MemoryKeychain, account: String, clock: FixedClock = FixedClock(Date(timeIntervalSince1970: 0)),
                      transport: StubTransport) -> DropboxTokenAuthorizer {
        let auth = DropboxAuth(appKey: "KEY", transport: transport, clock: clock, openURL: { _ in false })
        return DropboxTokenAuthorizer(auth: auth, keychain: keychain, keychainAccount: account, clock: clock)
    }

    @Test func keysAreScopedPerImport() {
        let id = SourceID.folder()
        #expect(DropboxTokenAuthorizer.importTokenKey(id) == "import-\(id.rawValue)")
        #expect(DropboxTokenAuthorizer.accountTokenKey == "dropbox-account")
    }

    @Test func refreshesFromTheStoredTokenAndCachesUntilExpiry() async throws {
        let keychain = MemoryKeychain()
        try keychain.write(Data("RT".utf8), account: "import-a")
        let transport = StubTransport { _ in .json(["access_token": "AT", "expires_in": 3600]) }
        let authorizer = make(keychain, account: "import-a", transport: transport)
        #expect(try await authorizer.accessToken(forceRefresh: false) == "AT")
        #expect(try await authorizer.accessToken(forceRefresh: false) == "AT")
        #expect(transport.requests.count == 1)
        _ = try await authorizer.accessToken(forceRefresh: true)
        #expect(transport.requests.count == 2)
        #expect(transport.requests.first?.form["refresh_token"] == "RT")
    }

    @Test func missingTokenMeansAccessRevoked() async throws {
        let authorizer = make(MemoryKeychain(), account: "import-a", transport: StubTransport { _ in StubResponse(status: 500) })
        await #expect(throws: SourceError.accessRevoked) { try await authorizer.accessToken(forceRefresh: false) }
        #expect(await authorizer.hasStoredToken() == false)
    }

    @Test func storeKeepsRefreshTokenUnderItsAccountOnly() async throws {
        let keychain = MemoryKeychain()
        let authorizer = make(keychain, account: "import-a", transport: StubTransport { _ in StubResponse(status: 500) })
        let signIn = DropboxSignIn(accessToken: DropboxAccessToken(token: "AT", expiresAt: Date(timeIntervalSince1970: 3600)),
                                   refreshToken: "RT", email: "me@example.com")
        try await authorizer.store(signIn)
        #expect(try keychain.read(account: "import-a") == Data("RT".utf8))
        #expect(try keychain.read(account: "import-b") == nil)
        #expect(try await authorizer.accessToken(forceRefresh: false) == "AT")
        try await authorizer.forget()
        #expect(try keychain.read(account: "import-a") == nil)
    }
}
