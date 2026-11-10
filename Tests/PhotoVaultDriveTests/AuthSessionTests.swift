import Foundation
import Testing
import PhotoVaultCore
@testable import PhotoVaultDrive

/// Each session gets its own clock: tests run in parallel, and one test advancing a shared clock
/// would expire another test's cached token.
private func session(keychain: InMemoryKeychainStore, clock: FixedClock = FixedClock(),
                     _ handler: @escaping @Sendable (RecordedRequest) throws -> StubResponse)
    -> (GoogleAuthSession, StubTransport) {
    let transport = StubTransport(handler)
    let oauth = OAuthClient(config: OAuthConfig(clientID: "client-1"), transport: transport, clock: clock, openURL: { _ in true })
    return (GoogleAuthSession(oauth: oauth, keychain: keychain, clock: clock), transport)
}

private let okToken: @Sendable (RecordedRequest) throws -> StubResponse = { r in
    r.url.path == "/token" ? .json(200, ["access_token": "access-\(r.form["refresh_token"] ?? "")", "expires_in": 3600]) : StubResponse(status: 200)
}

@Suite struct AuthSessionTests {
    @Test func refreshesLazilyAndCaches() async throws {
        let clock = FixedClock()
        let (auth, transport) = session(keychain: InMemoryKeychainStore(refreshToken: "r1"), clock: clock, okToken)
        #expect(try await auth.accessToken() == "access-r1")
        #expect(try await auth.accessToken() == "access-r1")
        #expect(transport.requests.count == 1)
        clock.advance(3600)
        _ = try await auth.accessToken()
        #expect(transport.requests.count == 2)
    }

    @Test func theDestinationRefreshStillRequiresDriveFile() async throws {
        let keychain = InMemoryKeychainStore(refreshToken: "r1")
        let (auth, _) = session(keychain: keychain) { _ in
            .json(200, ["access_token": "a", "expires_in": 3600, "scope": "openid email https://www.googleapis.com/auth/drive.readonly"])
        }
        await #expect(throws: DestinationError.reauthRequired) { try await auth.accessToken() }
    }

    @Test func missingKeychainItemMeansReauth() async throws {
        let (auth, transport) = session(keychain: InMemoryKeychainStore(), okToken)
        await #expect(throws: DestinationError.reauthRequired) { try await auth.accessToken() }
        #expect(transport.requests.isEmpty)
    }

    @Test func concurrentCallersShareOneRefresh() async throws {
        let (auth, transport) = session(keychain: InMemoryKeychainStore(refreshToken: "r1"), okToken)
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 { group.addTask { try await auth.accessToken() } }
            for try await _ in group {}
        }
        #expect(transport.requests.count == 1)
    }

    @Test func rotatedRefreshTokenIsStored() async throws {
        let keychain = InMemoryKeychainStore(refreshToken: "r1")
        let (auth, _) = session(keychain: keychain) { _ in .json(200, ["access_token": "a", "refresh_token": "r2", "expires_in": 3600]) }
        _ = try await auth.accessToken()
        #expect(keychain.refreshToken == "r2")
    }

    @Test func signOutDeletesKeychainFirstEvenWhenRevokeFails() async throws {
        let keychain = InMemoryKeychainStore(refreshToken: "r1")
        let seenAtRevoke = OpenedToken()
        let (auth, transport) = session(keychain: keychain) { r in
            seenAtRevoke.set(keychain.refreshToken ?? "<none>")
            throw URLError(.notConnectedToInternet, userInfo: [:])
        }
        try await auth.signOut()
        #expect(keychain.refreshToken == nil)
        #expect(seenAtRevoke.value == "<none>")
        #expect(transport.requests.first?.url.path == "/revoke")
        #expect(transport.requests.first?.form["token"] == "r1")
        await #expect(throws: DestinationError.reauthRequired) { try await auth.accessToken() }
    }

    @Test func signOutWithRevokeServerErrorStillWipes() async throws {
        let keychain = InMemoryKeychainStore(refreshToken: "r1")
        let (auth, _) = session(keychain: keychain) { _ in .json(500, ["error": "x"]) }
        try await auth.signOut()
        #expect(keychain.refreshToken == nil)
    }

    @Test func driveCallRefreshesOnceOn401() async throws {
        let counter = Counter()
        let (auth, oauthTransport) = session(keychain: InMemoryKeychainStore(refreshToken: "r1")) { _ in
            .json(200, ["access_token": "t\(counter.next())", "expires_in": 3600])
        }
        let drive = StubTransport { r in
            r.headers["Authorization"] == "Bearer t2" ? .json(200, ["ids": ["a"]]) : .json(401, ["error": ["errors": [["reason": "authError"]]]])
        }
        let ids = try await DriveAPI(transport: drive, auth: auth).generateIds(count: 1, kind: .files)
        #expect(ids == ["a"])
        #expect(drive.requests.map { $0.headers["Authorization"] } == ["Bearer t1", "Bearer t2"])
        #expect(oauthTransport.requests.count == 2)
    }

    @Test func persistent401BecomesUnauthorized() async throws {
        let (auth, _) = session(keychain: InMemoryKeychainStore(refreshToken: "r1")) { _ in .json(200, ["access_token": "t", "expires_in": 3600]) }
        let drive = StubTransport { _ in .json(401, ["error": ["errors": [["reason": "authError"]]]]) }
        await #expect(throws: DestinationError.unauthorized) { try await DriveAPI(transport: drive, auth: auth).generateIds(count: 1, kind: .files) }
        #expect(drive.requests.count == 2)
    }
}

final class OpenedToken: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    func set(_ v: String) { lock.withLock { if stored == nil { stored = v } } }
    var value: String? { lock.withLock { stored } }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}
