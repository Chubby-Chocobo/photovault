import Foundation
import Testing
import PhotoVaultCore
@testable import PhotoVaultDrive

@Suite struct PKCETests {
    @Test func matchesRFC7636AppendixB() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func verifierIs64Base64URLCharsAndUnique() throws {
        let a = try PKCE(), b = try PKCE()
        #expect(a.verifier.count == 64)
        #expect(a.verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(a.verifier != b.verifier)
        #expect(a.challenge == PKCE.challenge(for: a.verifier))
    }
}

@Suite struct LoopbackParsingTests {
    private func request(_ target: String, method: String = "GET") -> String {
        "\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
    }

    @Test func parsesCodeAndState() throws {
        let cb = try LoopbackRequestParser.parse(request("/oauth2/callback?code=4%2Fabc&state=s1"))
        #expect(cb == LoopbackCallback(code: "4/abc", state: "s1", error: nil))
        #expect(try LoopbackRequestParser.authorizationCode(from: cb, expectedState: "s1") == "4/abc")
    }

    @Test func stateMismatchIsRejected() throws {
        let cb = try LoopbackRequestParser.parse(request("/oauth2/callback?code=x&state=other"))
        #expect(throws: LoopbackError.stateMismatch) { try LoopbackRequestParser.authorizationCode(from: cb, expectedState: "s1") }
        let missing = try LoopbackRequestParser.parse(request("/oauth2/callback?code=x"))
        #expect(throws: LoopbackError.stateMismatch) { try LoopbackRequestParser.authorizationCode(from: missing, expectedState: "s1") }
    }

    @Test func errorParameterIsSurfaced() throws {
        let cb = try LoopbackRequestParser.parse(request("/oauth2/callback?error=access_denied&state=s1"))
        #expect(throws: LoopbackError.authorizationDenied("access_denied")) { try LoopbackRequestParser.authorizationCode(from: cb, expectedState: "s1") }
    }

    @Test func missingCodeIsRejected() throws {
        let cb = try LoopbackRequestParser.parse(request("/oauth2/callback?state=s1"))
        #expect(throws: LoopbackError.missingCode) { try LoopbackRequestParser.authorizationCode(from: cb, expectedState: "s1") }
    }

    @Test func wrongPathAndMalformedRequests() {
        #expect(throws: LoopbackError.wrongPath) { try LoopbackRequestParser.parse(request("/favicon.ico")) }
        #expect(throws: LoopbackError.wrongPath) { try LoopbackRequestParser.parse(request("/oauth2/callback/extra?code=x")) }
        #expect(throws: LoopbackError.malformedRequest) { try LoopbackRequestParser.parse(request("/oauth2/callback?code=x", method: "POST")) }
        #expect(throws: LoopbackError.malformedRequest) { try LoopbackRequestParser.parse("garbage") }
    }

    @Test func constantTimeCompare() {
        #expect(LoopbackRequestParser.constantTimeEquals("abc", "abc"))
        #expect(!LoopbackRequestParser.constantTimeEquals("abc", "abd"))
        #expect(!LoopbackRequestParser.constantTimeEquals("abc", "abcd"))
        #expect(!LoopbackRequestParser.constantTimeEquals("", "a"))
    }
}

@Suite struct LoopbackServerTests {
    private func fetch(_ port: UInt16, _ target: String) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)\(target)")!)
        return (data, (response as! HTTPURLResponse).statusCode)
    }

    @Test func bindsLoopbackAndDeliversCode() async throws {
        let server = try LoopbackRedirectServer(expectedState: "st")
        let port = try await server.start()
        #expect(port > 0)
        let (_, wrong) = try await fetch(port, "/favicon.ico")
        #expect(wrong == 404)
        let (page, status) = try await fetch(port, "/oauth2/callback?code=THE-CODE&state=st")
        #expect(status == 200)
        #expect(!String(decoding: page, as: UTF8.self).contains("THE-CODE"))
        #expect(try await server.awaitCode() == "THE-CODE")
        #expect(server.acceptedLocalHost?.hasPrefix("127.0.0.1") == true)
    }

    @Test func stateMismatchFailsTheFlow() async throws {
        let server = try LoopbackRedirectServer(expectedState: "st")
        let port = try await server.start()
        _ = try await fetch(port, "/oauth2/callback?code=c&state=evil")
        await #expect(throws: LoopbackError.stateMismatch) { try await server.awaitCode() }
    }

    @Test func timesOut() async throws {
        let server = try LoopbackRedirectServer(expectedState: "st", timeout: 0.2)
        _ = try await server.start()
        await #expect(throws: LoopbackError.timeout) { try await server.awaitCode() }
    }

    @Test func listenerStopsAfterFirstCallback() async throws {
        let server = try LoopbackRedirectServer(expectedState: "st")
        let port = try await server.start()
        _ = try await fetch(port, "/oauth2/callback?code=c&state=st")
        _ = try await server.awaitCode()
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: (any Error).self) { _ = try await fetch(port, "/oauth2/callback?code=c2&state=st") }
    }
}
