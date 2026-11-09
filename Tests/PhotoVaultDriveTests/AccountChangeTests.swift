import Foundation
import Testing
import PhotoVaultCore
@testable import PhotoVaultDrive

private let clock = FixedClock()
private let scope = "openid email https://www.googleapis.com/auth/drive.file"

private actor Gate {
    private(set) var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async {
        arrived += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}

/// Refresh-token grants block on `gate`; code exchanges answer with account B's tokens.
private struct GatedTransport: HTTPTransport {
    let gate: Gate
    var rotates = true
    func send(_ request: URLRequest, body: HTTPBody) async throws -> (Data, HTTPURLResponse) {
        let form = String(decoding: try body.load(), as: UTF8.self)
        let url = request.url!
        func reply(_ object: [String: Any]) throws -> (Data, HTTPURLResponse) {
            (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        if url.path == "/revoke" { return try reply([:]) }
        if form.contains("grant_type=refresh_token") {
            await gate.wait()
            var tokens: [String: Any] = ["access_token": "stale-access", "expires_in": 3600, "scope": scope]
            if rotates { tokens["refresh_token"] = "stale-rotated" }
            return try reply(tokens)
        }
        return try reply(["access_token": "access-B", "refresh_token": "refresh-B", "expires_in": 3600, "scope": scope,
                          "id_token": TestJWT.make(sub: "sub-B", email: "b@example.com", now: clock.now)])
    }
}

private func makeSession(keychain: any KeychainStore, gate: Gate = Gate(), rotates: Bool = true) -> GoogleAuthSession {
    let oauth = OAuthClient(config: OAuthConfig(clientID: "client-1"), transport: GatedTransport(gate: gate, rotates: rotates), clock: clock) { url in
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        Task { _ = try? await URLSession.shared.data(from: URL(string: "\(items["redirect_uri"]!)?code=c&state=\(items["state"]!)")!) }
        return true
    }
    return GoogleAuthSession(oauth: oauth, keychain: keychain, clock: clock)
}

private func waitUntilRefreshing(_ gate: Gate) async throws {
    for _ in 0..<200 {
        if await gate.arrived > 0 { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("refresh never started")
}

@Suite struct StaleRefreshTests {
    @Test func signOutDuringRefreshLeavesKeychainEmpty() async throws {
        let keychain = InMemoryKeychainStore(refreshToken: "refresh-A")
        let gate = Gate()
        let auth = makeSession(keychain: keychain, gate: gate)
        let pending = Task { try await auth.accessToken() }
        try await waitUntilRefreshing(gate)
        try await auth.signOut()
        await gate.open()
        await #expect(throws: DestinationError.reauthRequired) { try await pending.value }
        #expect(keychain.refreshToken == nil)
        await #expect(throws: DestinationError.reauthRequired) { try await auth.accessToken() }
    }

    @Test func signInDuringRefreshKeepsTheNewAccount() async throws {
        let keychain = InMemoryKeychainStore(refreshToken: "refresh-A")
        let gate = Gate()
        let auth = makeSession(keychain: keychain, gate: gate)
        let pending = Task { try await auth.accessToken() }
        try await waitUntilRefreshing(gate)
        let identity = try await auth.signIn()
        #expect(identity.sub == "sub-B")
        await gate.open()
        #expect(try await pending.value == "access-B")
        #expect(keychain.refreshToken == "refresh-B")
        #expect(try await auth.accessToken() == "access-B")
    }
}

private struct FailingWriteKeychain: KeychainStore {
    func read(account: String) throws -> Data? { Data("refresh-A".utf8) }
    func write(_ data: Data, account: String) throws { throw DestinationError.transient(reason: "keychain") }
    func delete(account: String) throws {}
}

@Suite struct StagedAccountChangeTests {
    @Test func beginKeepsOldAccountLiveAndCommitSwaps() async throws {
        let keychain = InMemoryKeychainStore(refreshToken: "refresh-A")
        let gate = Gate()
        let auth = makeSession(keychain: keychain, gate: gate, rotates: false)
        await gate.open()
        #expect(try await auth.accessToken() == "stale-access")
        let staged = try await auth.beginAccountChange()
        #expect(staged.identity == GoogleIdentity(sub: "sub-B", email: "b@example.com"))
        #expect(keychain.refreshToken == "refresh-A")
        #expect(try await auth.accessToken() == "stale-access")
        #expect(!"\(staged)".contains("refresh-B") && !"\(staged)".contains("access-B"))

        // The staged account authorizes requests on its own (root choice before commit) without going live.
        #expect(try await staged.accessToken() == "access-B")
        await #expect(throws: DestinationError.self) { _ = try await staged.refreshAfterUnauthorized(rejected: "access-B") }
        #expect(try await auth.accessToken() == "stale-access")

        try await auth.commitAccountChange(staged)
        #expect(keychain.refreshToken == "refresh-B")
        #expect(try await auth.accessToken() == "access-B")
        await #expect(throws: DestinationError.self) { try await auth.commitAccountChange(staged) }
    }

    @Test func discardLeavesOldAccountAndBlocksCommit() async throws {
        let keychain = InMemoryKeychainStore(refreshToken: "refresh-A")
        let auth = makeSession(keychain: keychain)
        let staged = try await auth.beginAccountChange()
        await auth.discardAccountChange(staged)
        #expect(keychain.refreshToken == "refresh-A")
        await #expect(throws: DestinationError.self) { try await auth.commitAccountChange(staged) }
        #expect(keychain.refreshToken == "refresh-A")
    }

    @Test func newerStageSupersedesOlder() async throws {
        let keychain = InMemoryKeychainStore(refreshToken: "refresh-A")
        let auth = makeSession(keychain: keychain)
        let first = try await auth.beginAccountChange()
        let second = try await auth.beginAccountChange()
        await #expect(throws: DestinationError.self) { try await auth.commitAccountChange(first) }
        try await auth.commitAccountChange(second)
        #expect(keychain.refreshToken == "refresh-B")
    }

    @Test func keychainFailureLeavesLiveCredentialsUntouched() async throws {
        let gate = Gate()
        await gate.open()
        let auth = makeSession(keychain: FailingWriteKeychain(), gate: gate, rotates: false)
        #expect(try await auth.accessToken() == "stale-access")
        let staged = try await auth.beginAccountChange()
        await #expect(throws: DestinationError.transient(reason: "keychain")) { try await auth.commitAccountChange(staged) }
        #expect(try await auth.accessToken() == "stale-access")
    }
}
