import Foundation
import PhotoVaultCore
import PhotoVaultDrive
import Testing
@testable import PhotoVaultDropbox

private func components(_ url: URL) -> [String: String] {
    var result: [String: String] = [:]
    for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { result[item.name] = item.value ?? "" }
    return result
}

/// The fixed redirect port is shared, so these tests run one after another.
@Suite(.serialized) struct DropboxAuthTests {
    @Test func authorizationURLCarriesPkceOfflineAndFixedRedirect() {
        let url = DropboxAuth.authorizationURL(appKey: "KEY", state: "ST", challenge: "CH")
        #expect(url.absoluteString.hasPrefix("https://www.dropbox.com/oauth2/authorize?"))
        let query = components(url)
        #expect(query["client_id"] == "KEY")
        #expect(query["response_type"] == "code")
        #expect(query["code_challenge"] == "CH")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["token_access_type"] == "offline")
        #expect(query["redirect_uri"] == "http://localhost:53682/oauth2/callback")
        #expect(query["state"] == "ST")
        #expect(query["scope"] == "files.metadata.read files.content.read account_info.read")
    }

    @Test func refreshFormAndExpiry() async throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_000))
        let transport = StubTransport { _ in .json(["access_token": "AT", "expires_in": 14400, "token_type": "bearer"]) }
        let auth = DropboxAuth(appKey: "KEY", transport: transport, clock: clock, openURL: { _ in false })
        let token = try await auth.refresh(refreshToken: "RT")
        let request = try #require(transport.requests.first)
        #expect(request.url.absoluteString == "https://api.dropboxapi.com/oauth2/token")
        #expect(request.form == ["grant_type": "refresh_token", "refresh_token": "RT", "client_id": "KEY"])
        #expect(token.token == "AT")
        #expect(token.expiresAt == Date(timeIntervalSince1970: 1_000 + 14_400))
        #expect("\(token)".contains("AT") == false)
    }

    @Test func invalidGrantOnRefreshIsAccessRevoked() async throws {
        let transport = StubTransport { _ in .json(400, ["error": "invalid_grant", "error_description": "refresh token is invalid or revoked"]) }
        let auth = DropboxAuth(appKey: "KEY", transport: transport, openURL: { _ in false })
        await #expect(throws: SourceError.accessRevoked) { try await auth.refresh(refreshToken: "RT") }
    }

    @Test func onlyAConfirmedDeadGrantIsRevoked() async throws {
        let cases: [(StubResponse, SourceError)] = [
            (.json(400, ["error": "invalid_client"]), .accessRevoked),
            (.json(401, ["error": "invalid_client"]), .accessRevoked),
            (.json(400, ["error": "invalid_request"]), .unavailable),
            (.json(400, [:]), .unavailable),
            (.json(403, ["error": "access_denied"]), .unavailable),
            (StubResponse(status: 429), .busy),
            (StubResponse(status: 503), .busy),
        ]
        for (response, expected) in cases {
            let auth = DropboxAuth(appKey: "KEY", transport: StubTransport { _ in response }, openURL: { _ in false })
            await #expect(throws: expected) { try await auth.refresh(refreshToken: "RT") }
        }
    }

    @Test func anUnreadableRefreshAnswerIsASourceErrorNotASignInError() async throws {
        let auth = DropboxAuth(appKey: "KEY", transport: StubTransport { _ in StubResponse(status: 200, body: Data("not json".utf8)) },
                               openURL: { _ in false })
        await #expect(throws: SourceError.unavailable) { try await auth.refresh(refreshToken: "RT") }
    }

    @Test func networkFailureOnRefreshIsUnavailable() async throws {
        let transport = StubTransport { _ in throw URLError(.timedOut) }
        let auth = DropboxAuth(appKey: "KEY", transport: transport, openURL: { _ in false })
        await #expect(throws: SourceError.unavailable) { try await auth.refresh(refreshToken: "RT") }
    }

    @Test func signInExchangesCodeOnTheFixedPortAndReturnsEmail() async throws {
        let transport = StubTransport { request in
            request.url.path == "/oauth2/token"
                ? .json(["access_token": "AT", "refresh_token": "RT", "expires_in": 14400])
                : .json(["email": "me@example.com"])
        }
        let browser = BrowserRecord()
        let auth = DropboxAuth(appKey: "KEY", transport: transport, openURL: { url in
            browser.set(url)
            let state = components(url)["state"] ?? ""
            Task { _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:53697/oauth2/callback?code=THE-CODE&state=\(state)")!) }
            return true
        }, port: 53_697)
        let result = try await auth.signIn()
        #expect(result.email == "me@example.com")
        #expect(result.refreshToken == "RT")
        #expect(result.accessToken.token == "AT")
        let exchange = try #require(transport.requests.first)
        let form = exchange.form
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["code"] == "THE-CODE")
        #expect(form["client_id"] == "KEY")
        #expect(form["redirect_uri"] == "http://localhost:53682/oauth2/callback")
        let challenge = components(try #require(browser.url))["code_challenge"]
        #expect(PKCE.challenge(for: form["code_verifier"] ?? "") == challenge)
        #expect(transport.requests.last?.headers["Authorization"] == "Bearer AT")
        #expect("\(result)" == "DropboxSignIn(<redacted>)")
    }

    @Test func occupiedPortGivesAClearError() async throws {
        let squatter = try LoopbackRedirectServer(expectedState: "s", port: 53_699)
        _ = try await squatter.start()
        defer { squatter.cancel() }
        let auth = DropboxAuth(appKey: "KEY", transport: StubTransport { _ in StubResponse(status: 500) }, openURL: { _ in true }, port: 53_699)
        await #expect(throws: DropboxAuthError.portInUse) { try await auth.signIn() }
    }

    @Test func unopenableBrowserIsReported() async throws {
        let transport = StubTransport { _ in StubResponse(status: 500) }
        await #expect(throws: DropboxAuthError.browserUnavailable) {
            try await DropboxAuth(appKey: "K", transport: transport, openURL: { _ in false }, port: 53_695).signIn()
        }
    }

    @Test func deniedConsentIsReportedBeforeAnyExchange() async throws {
        let transport = StubTransport { _ in StubResponse(status: 500) }
        let denied = DropboxAuth(appKey: "K", transport: transport, openURL: { url in
            let state = components(url)["state"] ?? ""
            Task { _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:53696/oauth2/callback?error=access_denied&state=\(state)")!) }
            return true
        }, port: 53_696)
        await #expect(throws: DropboxAuthError.denied) { try await denied.signIn() }
        #expect(transport.requests.isEmpty)
    }

    @Test func fixedPortServerBindsLoopback() async throws {
        let server = try LoopbackRedirectServer(expectedState: "st", port: DropboxAuth.redirectPort)
        let port = try await server.start()
        #expect(port == 53_682)
        let browser = Task { try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:53682/oauth2/callback?code=C&state=st")!) }
        #expect(try await server.awaitCode() == "C")
        server.respond(success: true)
        _ = try await browser.value
        #expect(server.acceptedLocalHost?.hasPrefix("127.0.0.1") == true)
    }
}

final class BrowserRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?
    var url: URL? { lock.withLock { stored } }
    func set(_ url: URL) { lock.withLock { stored = url } }
}

struct FixedClock: PhotoVaultCore.Clock {
    var now: Date
    init(_ now: Date) { self.now = now }
}
