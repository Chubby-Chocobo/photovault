import Foundation
import Testing
import PhotoVaultCore
@testable import PhotoVaultDrive

private let clock = FixedClock()

private func items(_ url: URL) -> [String: String] {
    Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
}

private let fileScope = "https://www.googleapis.com/auth/drive.file"
private let readScope = "https://www.googleapis.com/auth/drive.readonly"

/// Plays the browser. The Picker step (`trigger_onepick`) answers `pick`; the read step answers `read`. Every opened URL is kept.
private final class Browser: @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [URL] = []
    var urls: [URL] { lock.withLock { opened } }
    let pick: String
    let read: String
    init(pick: String = "&code=pick-code&picked_file_ids=f1,f2", read: String = "&code=read-code") { self.pick = pick; self.read = read }
    var opener: URLOpening {
        { [self] url in
            lock.withLock { opened.append(url) }
            let q = items(url)
            let extra = q["trigger_onepick"] == nil ? read : pick
            let target = URL(string: "\(q["redirect_uri"]!)?state=\(q["state"]!)\(extra)")!
            Task.detached { _ = try? await URLSession.shared.data(from: target) }
            return true
        }
    }
}

private func flow(_ transport: any HTTPTransport, opener: @escaping URLOpening, onReadStep: @escaping @Sendable () -> Void = {}) -> GooglePickerFlow {
    GooglePickerFlow(config: OAuthConfig(clientID: "client-1", clientSecret: "s"), transport: transport, clock: clock,
                     openURL: opener, loopbackTimeout: 5, onReadStep: onReadStep)
}

private let bothScopes = fileScope + " " + readScope

/// A Google that answers the pick code with a `drive.file` token and the read code with a `drive.readonly` token.
private func server(pickEmail: String? = "me@example.com", pickId: String? = "perm-1",
                    readEmail: String? = "me@example.com", readId: String? = "perm-1",
                    pickRefresh: String? = "r-pick", readRefresh: String? = "r-read",
                    pickScope: String = fileScope, readScope readGranted: String = readScope) -> StubTransport {
    StubTransport { request in
        if request.url.host == "oauth2.googleapis.com" {
            if request.form["token"] != nil { return .json(200, [:]) }
            let picking = request.form["code"] == "pick-code"
            var body: [String: Any] = ["access_token": picking ? "at-pick" : "at-read", "expires_in": 3600,
                                       "scope": picking ? pickScope : readGranted]
            if let refresh = picking ? pickRefresh : readRefresh { body["refresh_token"] = refresh }
            return .json(200, body)
        }
        let picking = request.headers["Authorization"] == "Bearer at-pick"
        let (email, id) = picking ? (pickEmail, pickId) : (readEmail, readId)
        guard email != nil || id != nil else { return .json(403, [:]) }
        var user: [String: Any] = [:]
        if let email { user["emailAddress"] = email }
        if let id { user["permissionId"] = id }
        return .json(200, ["user": user])
    }
}

private final class LockedPage: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data?) { lock.withLock { data = value ?? Data() } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Suite struct GooglePickerFlowTests {
    @Test func thePickerWaitsLongEnoughToChooseManyPhotos() {
        #expect(GooglePickerFlow.pickTimeout >= 15 * 60)
    }

    @Test func authorizationURLCarriesPickerParameters() {
        let url = GooglePickerFlow.authorizationURL(clientID: "c", redirectURI: "http://127.0.0.1:5/oauth2/callback", state: "s", challenge: "ch")
        let q = items(url)
        #expect(url.host == "accounts.google.com" && url.path == "/o/oauth2/v2/auth")
        #expect(q["scope"] == "https://www.googleapis.com/auth/drive.file", "Google refuses drive.file combined with any other scope for the Picker")
        #expect(q["trigger_onepick"] == "true" && q["allow_multiple"] == "true" && q["allow_folder_selection"] == "true")
        #expect(q["access_type"] == "offline" && q["prompt"] == "select_account consent" && q["response_type"] == "code")
        #expect(q["code_challenge_method"] == "S256" && q["state"] == "s" && q["client_id"] == "c")
        #expect(q["redirect_uri"] == "http://127.0.0.1:5/oauth2/callback")
    }

    @Test func readAuthorizationURLAsksForReadOnlyAndTheSameAccount() {
        let url = GooglePickerFlow.readAuthorizationURL(clientID: "c", redirectURI: "http://127.0.0.1:5/oauth2/callback", state: "s", challenge: "ch", loginHint: "me@example.com")
        let q = items(url)
        #expect(url.host == "accounts.google.com" && url.path == "/o/oauth2/v2/auth")
        #expect(q["scope"] == "https://www.googleapis.com/auth/drive.readonly")
        #expect(q["login_hint"] == "me@example.com" && q["prompt"] == "consent" && q["access_type"] == "offline")
        #expect(q["trigger_onepick"] == nil && q["allow_multiple"] == nil && q["allow_folder_selection"] == nil)
        #expect(q["code_challenge_method"] == "S256" && q["response_type"] == "code" && q["client_id"] == "c" && q["state"] == "s")
        let noHint = GooglePickerFlow.readAuthorizationURL(clientID: "c", redirectURI: "r", state: "s", challenge: "ch", loginHint: nil)
        #expect(items(noHint)["login_hint"] == nil)
    }

    @Test func destinationSignInStaysDriveFileOnly() {
        let url = OAuthClient.authorizationURL(clientID: "c", redirectURI: "http://127.0.0.1:5/oauth2/callback", state: "s", challenge: "ch")
        let scopes = Set((items(url)["scope"] ?? "").split(separator: " ").map(String.init))
        #expect(scopes == ["https://www.googleapis.com/auth/drive.file", "openid", "email"])
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
            let target = URL(string: "\(q["redirect_uri"]!)?state=\(q["state"]!)&code=pick-code&picked_file_ids=\(list)")!
            Task.detached { page.set(try? await URLSession.shared.data(from: target).0) }
            return true
        }
        await #expect(throws: PickerError.selectionTooLarge) { try await flow(server(), opener: opener).run() }
        for _ in 0..<100 where page.text.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(page.text.contains("Too many items"))
    }

    @Test func fullFlowAsksTwiceAndKeepsTheReadOnlyGrant() async throws {
        let transport = server()
        let browser = Browser()
        let steps = LockedCounter()
        let result = try await flow(transport, opener: browser.opener, onReadStep: { steps.increment() }).run()
        #expect(result.pickedIds == ["f1", "f2"] && result.email == "me@example.com")
        #expect(result.refreshToken == "r-read" && result.accessToken == "at-read", "the token kept is the drive.readonly one")
        #expect(result.expiresAt == clock.now.addingTimeInterval(3600))
        #expect("\(result)".contains("r-read") == false && "\(result)".contains("at-read") == false)
        #expect(steps.value == 1)
        let urls = browser.urls
        #expect(urls.count == 2)
        #expect(items(urls[0])["scope"] == fileScope && items(urls[0])["trigger_onepick"] == "true")
        #expect(items(urls[1])["scope"] == readScope && items(urls[1])["trigger_onepick"] == nil)
        #expect(items(urls[1])["login_hint"] == "me@example.com")
        let exchanges = transport.requests.filter { $0.url.host == "oauth2.googleapis.com" }
        #expect(exchanges.map { $0.form["code"] } == ["pick-code", "read-code"])
        #expect(exchanges.allSatisfy { $0.form["grant_type"] == "authorization_code" })
        #expect(!transport.requests.contains { $0.form["token"] != nil }, "no revoke: it would end the client's other grants for the account")
    }

    @Test func theStepOneGrantIsNeverReturned() async throws {
        let result = try await flow(server(), opener: Browser().opener).run()
        #expect(result.refreshToken != "r-pick" && result.accessToken != "at-pick")
    }

    @Test func aDifferentAccountInTheReadStepIsRefused() async throws {
        await #expect(throws: PickerError.accountMismatch) {
            try await flow(server(readEmail: "other@example.com", readId: "perm-2"), opener: Browser().opener).run()
        }
    }

    @Test func accountsAreComparedByPermissionIdWhenBothHaveOne() async throws {
        let sameIdOtherMail = try await flow(server(readEmail: "alias@example.com", readId: "perm-1"), opener: Browser().opener).run()
        #expect(sameIdOtherMail.pickedIds == ["f1", "f2"])
        await #expect(throws: PickerError.accountMismatch) {
            try await flow(server(readEmail: "me@example.com", readId: "perm-2"), opener: Browser().opener).run()
        }
    }

    @Test func withoutAPermissionIdTheEmailsAreCompared() async throws {
        _ = try await flow(server(pickId: nil, readId: nil), opener: Browser().opener).run()
        await #expect(throws: PickerError.accountMismatch) {
            try await flow(server(pickId: nil, readEmail: "other@example.com", readId: nil), opener: Browser().opener).run()
        }
    }

    @Test func anUnverifiableReadAccountIsRefused() async throws {
        await #expect(throws: PickerError.accountMismatch) {
            try await flow(server(readEmail: nil, readId: nil), opener: Browser().opener).run()
        }
    }

    @Test func noLoginHintWhenStepOneHadNoEmail() async throws {
        let browser = Browser()
        let result = try await flow(server(pickEmail: nil), opener: browser.opener).run()
        #expect(result.email == nil && items(browser.urls[1])["login_hint"] == nil)
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

    @Test func accountLookupFailureDoesNotFailThePick() async throws {
        let result = try await flow(server(pickEmail: nil, pickId: nil, readEmail: nil, readId: nil), opener: Browser().opener).run()
        #expect(result.email == nil && result.pickedIds == ["f1", "f2"] && result.refreshToken == "r-read")
    }

    @Test func cancelledConsentInTheFirstStepIsCancelled() async throws {
        let browser = Browser(pick: "&error=access_denied")
        await #expect(throws: PickerError.cancelled) { try await flow(server(), opener: browser.opener).run() }
        #expect(browser.urls.count == 1)
    }

    @Test func cancelledConsentInTheReadStepIsCancelled() async throws {
        await #expect(throws: PickerError.cancelled) {
            try await flow(server(), opener: Browser(read: "&error=access_denied").opener).run()
        }
    }

    @Test func cancellingTheTaskDuringTheReadStepStopsAtOnce() async throws {
        let opener: URLOpening = { url in
            let q = items(url)
            guard q["trigger_onepick"] != nil else { return true }
            let target = URL(string: "\(q["redirect_uri"]!)?state=\(q["state"]!)&code=pick-code&picked_file_ids=f1")!
            Task.detached { _ = try? await URLSession.shared.data(from: target) }
            return true
        }
        let waiting = GooglePickerFlow(config: OAuthConfig(clientID: "client-1", clientSecret: "s"), transport: server(), clock: clock,
                                       openURL: opener, loopbackTimeout: 60)
        let task = Task { try await waiting.run() }
        try await Task.sleep(for: .milliseconds(500))
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: PickerError.cancelled) { _ = try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func consentWithoutSelectionIsNothingPicked() async throws {
        let transport = server()
        await #expect(throws: PickerError.nothingPicked) {
            try await flow(transport, opener: Browser(pick: "&code=pick-code").opener).run()
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func missingRefreshTokenInTheReadStepIsReported() async throws {
        await #expect(throws: PickerError.tokenMissing) {
            try await flow(server(readRefresh: nil), opener: Browser().opener).run()
        }
    }

    @Test func aMissingStepOneRefreshTokenDoesNotMatter() async throws {
        let result = try await flow(server(pickRefresh: nil), opener: Browser().opener).run()
        #expect(result.refreshToken == "r-read")
    }

    @Test func aReadGrantWithoutReadAccessIsRefusedAndNothingIsKept() async throws {
        await #expect(throws: PickerError.readAccessDenied) {
            try await flow(server(readScope: fileScope), opener: Browser().opener).run()
        }
    }

    @Test func aReadTokenResponseWithoutScopeCountsAsNoReadAccess() async throws {
        let transport = StubTransport { request in
            if request.form["code"] == "pick-code" { return .json(200, ["access_token": "a", "refresh_token": "r", "expires_in": 3600, "scope": fileScope]) }
            return .json(200, ["access_token": "b", "refresh_token": "r2", "expires_in": 3600])
        }
        await #expect(throws: PickerError.readAccessDenied) { try await flow(transport, opener: Browser().opener).run() }
    }

    @Test func aGrantWithoutTheFilePermissionIsRefusedWithItsOwnError() async throws {
        let transport = server(pickScope: readScope)
        let browser = Browser()
        await #expect(throws: PickerError.pickAccessDenied) { try await flow(transport, opener: browser.opener).run() }
        #expect(browser.urls.count == 1, "the read step never starts")
    }

    @Test func browserFailureIsReported() async throws {
        await #expect(throws: PickerError.browserUnavailable) { try await flow(server(), opener: { _ in false }).run() }
    }

    @Test func browserFailureInTheReadStepIsReported() async throws {
        let first = Browser()
        let opener: URLOpening = { url in
            guard items(url)["trigger_onepick"] != nil else { return false }
            return await first.opener(url)
        }
        await #expect(throws: PickerError.browserUnavailable) { try await flow(server(), opener: opener).run() }
    }

    @Test func pickerResultIsRedactedInDescription() {
        let r = PickerResult(pickedIds: ["id"], refreshToken: "secret-r", accessToken: "secret-a", expiresAt: clock.now, email: "x@y.z")
        #expect(!"\(r)".contains("secret") && !"\(r)".contains("x@y.z") && !String(reflecting: r).contains("secret-r"))
    }
}
