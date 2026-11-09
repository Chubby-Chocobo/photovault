import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultDrive

/// A Picker redirect lists every picked id, so a big selection makes a long request line.
@Suite struct LoopbackLargeCallbackTests {
    private func ids(_ count: Int) -> String {
        (0..<count).map { "1" + String(format: "%032d", $0) }.joined(separator: ",")
    }

    private func fetch(_ port: UInt16, _ target: String) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)\(target)")!)
        return (data, (response as! HTTPURLResponse).statusCode)
    }

    @Test func twoThousandPickedIdsReachTheApp() async throws {
        let server = try LoopbackRedirectServer(expectedState: "st")
        let port = try await server.start()
        let list = ids(2000)
        let browser = Task { try await fetch(port, "/oauth2/callback?code=c&state=st&picked_file_ids=\(list)") }
        #expect(try await server.awaitCode() == "c")
        server.respond(success: true)
        #expect(try await browser.value.1 == 200)
        #expect(server.receivedCallback?.pickedFileIds == list)
    }

    @Test func theLargestAcceptedSelectionFitsTheRequestLimit() {
        // Drive ids are at most about 45 bytes, and a comma may arrive percent-encoded (3 bytes).
        #expect(GooglePickerFlow.maxPickedIds * 48 < LoopbackRequestParser.maxRequestBytes)
    }

    @Test func aRequestLineBeyondTheLimitEndsTheFlowAtOnceWithAReadablePage() async throws {
        let server = try LoopbackRedirectServer(expectedState: "st")
        let port = try await server.start()
        let huge = String(repeating: "A", count: LoopbackRequestParser.maxRequestBytes + 1000)
        let browser = Task { try? await fetch(port, "/oauth2/callback?code=c&state=st&picked_file_ids=\(huge)") }
        await #expect(throws: LoopbackError.requestTooLarge) { try await server.awaitCode() }
        let reply = await browser.value
        #expect(reply?.1 == 400 && String(decoding: reply?.0 ?? Data(), as: UTF8.self).contains("Too many items"))
    }

    @Test func anOversizedRequestWithoutTheStateLeavesTheFlowWaiting() async throws {
        let server = try LoopbackRedirectServer(expectedState: "st")
        let port = try await server.start()
        let waiting = Task { try await server.awaitCode() }
        let huge = String(repeating: "A", count: LoopbackRequestParser.maxRequestBytes + 1000)
        let stray = try? await fetch(port, "/oauth2/callback?x=\(huge)")
        #expect(stray?.1 == 413)
        let real = Task { try await fetch(port, "/oauth2/callback?code=c&state=st") }
        #expect(try await waiting.value == "c")
        server.respond(success: true)
        #expect(try await real.value.1 == 200)
    }

    @Test func thePickerFlowFailsFastWhenTheSelectionIsTooLarge() async throws {
        let huge = String(repeating: "A", count: LoopbackRequestParser.maxRequestBytes + 1000)
        let opener: URLOpening = { url in
            let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            let target = URL(string: "\(q["redirect_uri"]!)?state=\(q["state"]!)&code=c&picked_file_ids=\(huge)")!
            Task.detached { _ = try? await URLSession.shared.data(from: target) }
            return true
        }
        let flow = GooglePickerFlow(
            config: OAuthConfig(clientID: "client-1", clientSecret: "s"), transport: StubTransport { _ in .json(500, [:]) },
            clock: FixedClock(), openURL: opener, loopbackTimeout: 30)
        await #expect(throws: PickerError.selectionTooLarge) { _ = try await flow.run() }
    }
}
