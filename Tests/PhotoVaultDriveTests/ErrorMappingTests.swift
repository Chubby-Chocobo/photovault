import Foundation
import Testing
import PhotoVaultCore
@testable import PhotoVaultDrive

private let clock = FixedClock()

private func response(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://www.googleapis.com/x")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}

private func body(_ reason: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["error": ["errors": [["reason": reason]]]])
}

@Suite struct DriveErrorMapperTests {
    @Test func retryAfterAcceptsSecondsAndHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(DriveErrorMapper.retryAfter(response(429, ["Retry-After": "12"]), now: now) == 12)
        let date = "Fri, 15 Jan 2027 08:01:00 GMT"  // 1_800_000_060 s since epoch
        #expect(DriveErrorMapper.retryAfter(response(429, ["Retry-After": date]), now: now) == 60)
        #expect(DriveErrorMapper.retryAfter(response(429, ["Retry-After": date]), now: now.addingTimeInterval(500)) == 0)
        #expect(DriveErrorMapper.retryAfter(response(429, ["Retry-After": "soon"]), now: now) == nil)
        #expect(DriveErrorMapper.retryAfter(response(429), now: now) == nil)
    }

    @Test(arguments: ["dailyLimitExceeded", "sharingRateLimitExceeded", "rateLimitExceeded", "userRateLimitExceeded"])
    func throttling403IsRateLimitedNotForbidden(reason: String) {
        let error = DriveErrorMapper.error(data: body(reason), response: response(403, ["Retry-After": "5"]))
        #expect(error == .rateLimited(retryAfter: 5))
        #expect(error.map(DriveErrorMapper.isForbidden) == false)
    }

    @Test func onlyPermissionReasonsAreForbidden() {
        for reason in ["insufficientPermissions", "forbidden"] {
            #expect(DriveErrorMapper.error(data: body(reason), response: response(403)).map(DriveErrorMapper.isForbidden) == true)
        }
        #expect(DriveErrorMapper.error(data: body("somethingElse"), response: response(403)).map(DriveErrorMapper.isForbidden) == false)
    }

    @Test func throttledShortcutCallIsNotViewsNotPermitted() async throws {
        let h = try await Harness.make(transport: { server in
            InterceptingTransport(base: server) { request in
                request.url?.path == "/drive/v3/files" && request.httpMethod == "POST"
                    ? .json(403, ["error": ["errors": [["reason": "sharingRateLimitExceeded"]]]]) : nil
            }
        })
        let a = try await h.folder("a")
        h.interceptor?.arm()
        let sid = try await h.destination.reserveIds(count: 1, kind: .shortcuts)[0]
        await #expect(throws: DestinationError.rateLimited(retryAfter: nil)) {
            try await h.destination.createShortcut(ShortcutRequest(reservedId: sid, targetId: "T", parent: a, name: "s", appProperties: [:]))
        }
    }
}

@Suite struct RefreshFailureMappingTests {
    private func oauth(_ handler: @escaping @Sendable (RecordedRequest) throws -> StubResponse) -> OAuthClient {
        OAuthClient(config: OAuthConfig(clientID: "client-1"), transport: StubTransport(handler), clock: clock, openURL: { _ in true })
    }

    @Test(arguments: [
        StubResponse.json(400, ["error": "unauthorized_client"]),
        StubResponse.json(400, ["error": "invalid_request"]),
        StubResponse.json(403, ["error": "access_denied"]),
        StubResponse(status: 200, body: Data("not json".utf8)),
        StubResponse.json(200, ["access_token": "a", "expires_in": 3600, "scope": "openid email"]),
    ])
    func unusableGrantIsReauthRequired(reply: StubResponse) async {
        await #expect(throws: DestinationError.reauthRequired) { try await oauth { _ in reply }.refresh(refreshToken: "r") }
    }

    @Test func transientFailuresKeepTheirClass() async {
        await #expect(throws: DestinationError.server(status: 503)) { try await oauth { _ in .json(503, ["error": "x"]) }.refresh(refreshToken: "r") }
        await #expect(throws: DestinationError.rateLimited(retryAfter: nil)) { try await oauth { _ in .json(429, ["error": "x"]) }.refresh(refreshToken: "r") }
        await #expect(throws: DestinationError.offline) { try await oauth { _ in throw URLError(.notConnectedToInternet) }.refresh(refreshToken: "r") }
    }

    @Test func failedExchangeShowsFailurePageInTheBrowser() async throws {
        let page = PageBox()
        let client = OAuthClient(config: OAuthConfig(clientID: "client-1"),
                                 transport: StubTransport { _ in .json(400, ["error": "invalid_request"]) }, clock: clock) { url in
            let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            page.task = Task {
                let target = "\(items["redirect_uri"]!)?code=c&state=\(items["state"]!)"
                let (data, _) = try await URLSession.shared.data(from: URL(string: target)!)
                return String(decoding: data, as: UTF8.self)
            }
            return true
        }
        await #expect(throws: DestinationError.self) { try await client.signIn() }
        let text = try await page.task?.value ?? ""
        #expect(text.contains("Sign-in failed"))
    }
}

final class PageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Task<String, any Error>?
    var task: Task<String, any Error>? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
