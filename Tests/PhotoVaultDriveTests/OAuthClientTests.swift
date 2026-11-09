import Foundation
import Testing
import PhotoVaultCore
@testable import PhotoVaultDrive

private let clock = FixedClock()

private func tokenJSON(refresh: String? = "refresh-1", id: String? = nil, scope: String? = nil) -> StubResponse {
    var body: [String: Any] = ["access_token": "access-1", "expires_in": 3599, "token_type": "Bearer"]
    if let refresh { body["refresh_token"] = refresh }
    if let id { body["id_token"] = id }
    if let scope { body["scope"] = scope }
    return .json(200, body)
}

private func client(_ transport: StubTransport, opener: @escaping URLOpening = { _ in true }) -> OAuthClient {
    OAuthClient(config: OAuthConfig(clientID: "client-1", clientSecret: "secret-1"), transport: transport, clock: clock, openURL: opener)
}

@Suite struct OAuthClientTests {
    @Test func authorizationURLShape() throws {
        let url = OAuthClient.authorizationURL(clientID: "client-1", redirectURI: "http://127.0.0.1:5555/oauth2/callback", state: "st", challenge: "ch")
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        #expect(url.host == "accounts.google.com" && url.path == "/o/oauth2/v2/auth")
        #expect(items["scope"] == "https://www.googleapis.com/auth/drive.file openid email")
        #expect(items["access_type"] == "offline" && items["prompt"] == "select_account consent")
        #expect(items["code_challenge_method"] == "S256" && items["code_challenge"] == "ch")
        #expect(items["redirect_uri"] == "http://127.0.0.1:5555/oauth2/callback")
        #expect(items["response_type"] == "code" && items["state"] == "st")
    }

    @Test func exchangeAndRefreshRequestShapes() async throws {
        let transport = StubTransport { _ in tokenJSON() }
        let oauth = client(transport)
        let tokens = try await oauth.exchange(code: "c o/de", verifier: "ver", redirectURI: "http://127.0.0.1:1/oauth2/callback")
        #expect(tokens.accessToken == "access-1" && tokens.refreshToken == "refresh-1")
        #expect(tokens.expiresAt == clock.now.addingTimeInterval(3599))
        _ = try await oauth.refresh(refreshToken: "refresh-1")
        let (exchange, refresh) = (transport.requests[0], transport.requests[1])
        #expect(exchange.url.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(exchange.form["grant_type"] == "authorization_code" && exchange.form["code"] == "c o/de")
        #expect(exchange.form["code_verifier"] == "ver" && exchange.form["client_secret"] == "secret-1")
        #expect(refresh.form["grant_type"] == "refresh_token" && refresh.form["refresh_token"] == "refresh-1")
        #expect(exchange.headers["Content-Type"] == "application/x-www-form-urlencoded")
    }

    @Test func invalidGrantRequiresReauth() async throws {
        let transport = StubTransport { _ in .json(400, ["error": "invalid_grant", "error_description": "Token has been expired or revoked."]) }
        await #expect(throws: DestinationError.reauthRequired) { try await client(transport).refresh(refreshToken: "dead") }
    }

    @Test func otherTokenErrorsAreClassified() async throws {
        let transport = StubTransport { _ in .json(503, ["error": "backend"]) }
        await #expect(throws: DestinationError.server(status: 503)) { try await client(transport).refresh(refreshToken: "r") }
    }

    @Test func missingDriveScopeIsRejected() async throws {
        let transport = StubTransport { _ in tokenJSON(scope: "openid email") }
        await #expect(throws: DestinationError.itemRejected(reason: "drive.file scope not granted")) {
            try await client(transport).exchange(code: "c", verifier: "v", redirectURI: "r")
        }
    }

    @Test func revokeSendsToken() async throws {
        let transport = StubTransport { _ in StubResponse(status: 200) }
        try await client(transport).revoke(token: "refresh-1")
        #expect(transport.requests[0].url.absoluteString == "https://oauth2.googleapis.com/revoke")
        #expect(transport.requests[0].form["token"] == "refresh-1")
    }

    @Test func fullSignInThroughRealLoopback() async throws {
        let jwt = TestJWT.make(now: clock.now)
        let transport = StubTransport { _ in tokenJSON(id: jwt, scope: "openid email https://www.googleapis.com/auth/drive.file") }
        let opened = OpenedURL()
        let oauth = client(transport) { url in
            opened.set(url)
            let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            Task {
                let target = "\(items["redirect_uri"]!)?code=AUTH-CODE&state=\(items["state"]!)"
                _ = try? await URLSession.shared.data(from: URL(string: target)!)
            }
            return true
        }
        let result = try await oauth.signIn()
        #expect(result.identity == GoogleIdentity(sub: "sub-123", email: "a@example.com"))
        let exchange = transport.requests[0]
        #expect(exchange.form["code"] == "AUTH-CODE")
        #expect(exchange.form["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
        let challenge = URLComponents(url: opened.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "code_challenge" }!.value
        #expect(PKCE.challenge(for: exchange.form["code_verifier"]!) == challenge)
    }

    @Test func browserFailureCancelsTheListener() async throws {
        let oauth = client(StubTransport { _ in tokenJSON() }, opener: { _ in false })
        await #expect(throws: DestinationError.transient(reason: "browser could not be opened")) { try await oauth.signIn() }
    }
}

final class OpenedURL: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URL?
    func set(_ url: URL) { lock.withLock { value = url } }
    var url: URL? { lock.withLock { value } }
}

@Suite struct IDTokenTests {
    private func identity(_ jwt: String) throws -> GoogleIdentity { try IDToken.identity(from: jwt, clientID: "client-1", now: clock.now) }

    @Test func acceptsValidClaimsFromBothIssuers() throws {
        #expect(try identity(TestJWT.make(now: clock.now)).sub == "sub-123")
        #expect(try identity(TestJWT.make(iss: "accounts.google.com", now: clock.now)).email == "a@example.com")
    }

    @Test func rejectsWrongAudienceIssuerExpiryAndGarbage() {
        #expect(throws: DestinationError.itemRejected(reason: "id token audience")) { try identity(TestJWT.make(aud: "other", now: clock.now)) }
        #expect(throws: DestinationError.itemRejected(reason: "id token issuer")) { try identity(TestJWT.make(iss: "https://evil.example", now: clock.now)) }
        #expect(throws: DestinationError.itemRejected(reason: "id token expired")) {
            try identity(TestJWT.make(exp: clock.now.timeIntervalSince1970 - 1, now: clock.now))
        }
        #expect(throws: DestinationError.itemRejected(reason: "id token malformed")) { try identity("not-a-jwt") }
    }

    @Test func audienceMayBeAnArray() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["aud": ["x", "client-1"], "iss": "accounts.google.com",
                                                                   "exp": clock.now.timeIntervalSince1970 + 60, "sub": "s"])
        #expect(try identity("e30.\(Base64URL.encode(payload)).sig").sub == "s")
    }
}
