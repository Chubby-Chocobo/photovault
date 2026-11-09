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
