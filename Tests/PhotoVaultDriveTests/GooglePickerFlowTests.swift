import Foundation
import Testing
import PhotoVaultCore
@testable import PhotoVaultDrive

private let clock = FixedClock()

private func items(_ url: URL) -> [String: String] {
    Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
}

/// Plays the browser: opens the redirect with `extra` appended once the authorization URL is "opened".
private func browser(_ extra: @escaping @Sendable (String) -> String) -> URLOpening {
    { url in
        let q = items(url)
        let target = URL(string: "\(q["redirect_uri"]!)?state=\(q["state"]!)\(extra(q["state"]!))")!
        Task.detached { _ = try? await URLSession.shared.data(from: target) }
        return true
    }
}

private func flow(_ transport: any HTTPTransport, opener: @escaping URLOpening) -> GooglePickerFlow {
    GooglePickerFlow(config: OAuthConfig(clientID: "client-1", clientSecret: "s"), transport: transport, clock: clock,
                     openURL: opener, loopbackTimeout: 5)
}

private func server(email: String? = "me@example.com", refresh: String? = "r-1") -> StubTransport {
    StubTransport { request in
        if request.url.host == "oauth2.googleapis.com" {
            var body: [String: Any] = ["access_token": "at-1", "expires_in": 3600, "scope": "https://www.googleapis.com/auth/drive.file"]
            if let refresh { body["refresh_token"] = refresh }
            return .json(200, body)
        }
        return email.map { .json(200, ["user": ["emailAddress": $0]]) } ?? .json(403, [:])
    }
}

private final class LockedPage: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data?) { lock.withLock { data = value ?? Data() } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

@Suite struct GooglePickerFlowTests {
    @Test func thePickerWaitsLongEnoughToChooseManyPhotos() {
        #expect(GooglePickerFlow.pickTimeout >= 15 * 60)
    }

    @Test func authorizationURLCarriesPickerParameters() {
        let url = GooglePickerFlow.authorizationURL(clientID: "c", redirectURI: "http://127.0.0.1:5/oauth2/callback", state: "s", challenge: "ch")
        let q = items(url)
        #expect(url.host == "accounts.google.com" && url.path == "/o/oauth2/v2/auth")
        #expect(q["scope"] == "https://www.googleapis.com/auth/drive.file")
        #expect(q["trigger_onepick"] == "true" && q["allow_multiple"] == "true" && q["allow_folder_selection"] == "true")
        #expect(q["access_type"] == "offline" && q["prompt"] == "select_account consent" && q["response_type"] == "code")
        #expect(q["code_challenge_method"] == "S256" && q["state"] == "s" && q["client_id"] == "c")
        #expect(q["redirect_uri"] == "http://127.0.0.1:5/oauth2/callback")
    }

    @Test func parserReadsPickedIds() throws {
        let callback = try LoopbackRequestParser.parse("GET /oauth2/callback?code=c&state=s&picked_file_ids=a1,b-2 HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(callback.pickedFileIds == "a1,b-2" && callback.code == "c")
    }

    @Test func idsAreValidatedAndDeduplicated() throws {
        #expect(try GooglePickerFlow.parseIds("a1, b_2,a1,,bad id,x/y,../z,C-3") == ["a1", "b_2", "C-3"])
        #expect(try GooglePickerFlow.parseIds(nil).isEmpty)
    }

    private func manyIds(_ count: Int) -> String {
        (0..<count).map { "1" + String(format: "%032d", $0) }.joined(separator: ",")
    }

    @Test func aSelectionAboveTheLimitIsRefusedNotCut() throws {
        #expect(try GooglePickerFlow.parseIds(manyIds(GooglePickerFlow.maxPickedIds)).count == GooglePickerFlow.maxPickedIds)
        #expect(throws: PickerError.selectionTooLarge) { try GooglePickerFlow.parseIds(manyIds(GooglePickerFlow.maxPickedIds + 1)) }
    }

    @Test func theFlowFailsWhenMoreItemsComeBackThanTheAppTakesAndTheBrowserSaysSo() async throws {
        let list = manyIds(GooglePickerFlow.maxPickedIds + 1)
        let page = LockedPage()
        let opener: URLOpening = { url in
            let q = items(url)
            let target = URL(string: "\(q["redirect_uri"]!)?state=\(q["state"]!)&code=c&picked_file_ids=\(list)")!
            Task.detached { page.set(try? await URLSession.shared.data(from: target).0) }
            return true
        }
        await #expect(throws: PickerError.selectionTooLarge) { try await flow(server(), opener: opener).run() }
        for _ in 0..<100 where page.text.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(page.text.contains("Too many items"))
    }

    @Test func fullFlowReturnsPickAndTokens() async throws {
        let transport = server()
        let result = try await flow(transport, opener: browser { _ in "&code=the-code&picked_file_ids=f1,f2" }).run()
        #expect(result.pickedIds == ["f1", "f2"] && result.refreshToken == "r-1" && result.accessToken == "at-1")
        #expect(result.email == "me@example.com")
        #expect(result.expiresAt == clock.now.addingTimeInterval(3600))
        #expect("\(result)".contains("r-1") == false && "\(result)".contains("at-1") == false)
        let exchange = transport.requests.first { $0.url.host == "oauth2.googleapis.com" }
        #expect(exchange?.form["code"] == "the-code" && exchange?.form["grant_type"] == "authorization_code")
        #expect(transport.requests.last?.headers["Authorization"] == "Bearer at-1")
    }

    @Test func cancellingTheTaskStopsWaitingForTheBrowserAtOnce() async throws {
        let waiting = GooglePickerFlow(
            config: OAuthConfig(clientID: "client-1", clientSecret: "s"), transport: server(), clock: clock,
            openURL: { _ in true }, loopbackTimeout: 60)
        let task = Task { try await waiting.run() }
        try await Task.sleep(for: .milliseconds(200))
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: PickerError.cancelled) { _ = try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func emailFailureDoesNotFailThePick() async throws {
        let result = try await flow(server(email: nil), opener: browser { _ in "&code=c&picked_file_ids=f1" }).run()
        #expect(result.email == nil && result.pickedIds == ["f1"])
    }

    @Test func cancelledConsentIsCancelled() async throws {
        await #expect(throws: PickerError.cancelled) {
            try await flow(server(), opener: browser { _ in "&error=access_denied" }).run()
        }
    }

    @Test func consentWithoutSelectionIsNothingPicked() async throws {
        let transport = server()
        await #expect(throws: PickerError.nothingPicked) {
            try await flow(transport, opener: browser { _ in "&code=c" }).run()
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func missingRefreshTokenIsReported() async throws {
        await #expect(throws: PickerError.tokenMissing) {
            try await flow(server(refresh: nil), opener: browser { _ in "&code=c&picked_file_ids=f1" }).run()
        }
    }

    @Test func browserFailureIsReported() async throws {
        await #expect(throws: PickerError.browserUnavailable) { try await flow(server(), opener: { _ in false }).run() }
    }

    @Test func pickerResultIsRedactedInDescription() {
        let r = PickerResult(pickedIds: ["id"], refreshToken: "secret-r", accessToken: "secret-a", expiresAt: clock.now, email: "x@y.z")
        #expect(!"\(r)".contains("secret") && !"\(r)".contains("x@y.z") && !String(reflecting: r).contains("secret-r"))
    }
}
