import Foundation
import Network
import PhotoVaultCore
import PhotoVaultTestSupport
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
        server.respond(.success)
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
        server.respond(.success)
        #expect(try await real.value.1 == 200)
    }

    @Test func anOversizedPickWhoseStateComesAfterTheIdsStillEndsTheFlowAtOnce() async throws {
        let server = try LoopbackRedirectServer(expectedState: "st")
        let port = try await server.start()
        let huge = String(repeating: "A", count: LoopbackRequestParser.maxRequestBytes + 1000)
        let browser = Task { try? await fetch(port, "/oauth2/callback?picked_file_ids=\(huge)&code=c&state=st") }
        await #expect(throws: LoopbackError.requestTooLarge) { try await server.awaitCode() }
        let reply = await browser.value
        #expect(reply?.1 == 400 && String(decoding: reply?.0 ?? Data(), as: UTF8.self).contains("Too many items"))
    }

    /// Cuts in the request, counted from the start of `state=`: the key is bytes 0 to 5, the value 6 to 48, and the
    /// space after it is byte 49. A cut at -1100 is below the size limit, so only a later piece makes the request oversized.
    @Test(arguments: [[-1], [3], [6], [26], [48], [49], [10, 30], [-1100, 26]])
    func anOversizedPickWhoseStateIsSplitAcrossReadsStillEndsTheFlowAtOnce(cuts: [Int]) async throws {
        let state = String(repeating: "s", count: 43)
        // The server's time limits are hang guards: on a loaded runner the next piece can go out many seconds later.
        let server = try LoopbackRedirectServer(expectedState: state, connectionTimeout: LoopbackRedirectServer.defaultTimeout)
        let port = try await server.start()
        let huge = String(repeating: "A", count: LoopbackRequestParser.maxRequestBytes + 1000)
        let request = Data("GET /oauth2/callback?picked_file_ids=\(huge)&code=c&state=\(state) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        let stateStart = try #require(request.range(of: Data("&state=".utf8))).lowerBound + 1
        let bounds = cuts.map { stateStart + $0 }
        let pieces = zip([0] + bounds, bounds + [request.count]).map { request[$0..<$1] }
        let socket = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        socket.start(queue: .global())
        defer { socket.cancel() }
        for piece in pieces {
            socket.send(content: piece, completion: .contentProcessed { _ in })
            guard piece.endIndex < request.count else { break }
            // Waiting until the server has read the piece puts the next one in a later read, however the bytes travel.
            #expect(await pollUntil { server.receivedByteCount == piece.endIndex })
        }
        await #expect(throws: LoopbackError.requestTooLarge) { try await server.awaitCode() }
    }

    @Test func aStrayRequestMuchLargerThanTheLimitIsRefusedWithoutEndingTheFlow() async throws {
        let server = try LoopbackRedirectServer(expectedState: "st")
        let port = try await server.start()
        let waiting = Task { try await server.awaitCode() }
        let huge = String(repeating: "A", count: 5 * LoopbackRequestParser.maxRequestBytes)
        let stray = try? await fetch(port, "/oauth2/callback?x=\(huge)")
        #expect(stray == nil || stray?.1 == 413)
        let real = Task { try await fetch(port, "/oauth2/callback?code=c&state=st") }
        #expect(try await waiting.value == "c")
        server.respond(.success)
        _ = try await real.value
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
            clock: FixedClock(), openURL: opener, loopbackTimeout: LoopbackRedirectServer.defaultTimeout)
        await #expect(throws: PickerError.selectionTooLarge) { _ = try await flow.run() }
    }
}
