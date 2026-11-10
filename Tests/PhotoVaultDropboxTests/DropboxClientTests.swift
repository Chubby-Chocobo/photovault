import CryptoKit
import Foundation
import PhotoVaultCore
import PhotoVaultDrive
import Testing
@testable import PhotoVaultDropbox

@Suite struct DropboxClientTests {
    private func page(_ entries: [[String: Any]], cursor: String = "c1", more: Bool = false) -> StubResponse {
        .json(["entries": entries, "cursor": cursor, "has_more": more])
    }

    @Test func listingFollowsCursorAcrossPages() async throws {
        let transport = StubTransport { request in
            if request.url.path.hasSuffix("list_folder/continue") {
                #expect(request.json["cursor"] as? String == "c1")
                return self.page([[".tag": "file", "name": "b.jpg", "path_display": "/b.jpg"]], cursor: "c2")
            }
            #expect(request.json["path"] as? String == "")
            #expect(request.json["recursive"] as? Bool == true)
            #expect(request.json["limit"] as? Int == 2000)
            #expect(request.json["include_non_downloadable_files"] as? Bool == false)
            #expect(request.headers["Authorization"] == "Bearer old-token")
            return self.page([[".tag": "file", "name": "a.jpg", "path_display": "/a.jpg"]], more: true)
        }
        let entries = try await makeClient(transport: transport).listAll(path: "", recursive: true)
        #expect(entries.map(\.name) == ["a.jpg", "b.jpg"])
        #expect(transport.requests.count == 2)
    }

    @Test func browsingReturnsFoldersOnlySortedByName() async throws {
        let transport = StubTransport { request in
            #expect(request.json["recursive"] as? Bool == false)
            return self.page([
                [".tag": "file", "name": "x.jpg", "path_display": "/x.jpg"],
                [".tag": "folder", "name": "zeta", "path_display": "/zeta"],
                [".tag": "folder", "name": "Alpha", "path_display": "/Alpha"],
            ])
        }
        let folders = try await makeClient(transport: transport).listFolders(path: "")
        #expect(folders == [DropboxFolder(name: "Alpha", path: "/Alpha"), DropboxFolder(name: "zeta", path: "/zeta")])
    }

    @Test func accountEmailComesFromGetCurrentAccountWithoutBody() async throws {
        let transport = StubTransport { request in
            #expect(request.url.absoluteString == "https://api.dropboxapi.com/2/users/get_current_account")
            #expect(request.body.isEmpty)
            #expect(request.headers["Content-Type"] == nil)
            return .json(["email": "me@example.com"])
        }
        #expect(try await makeClient(transport: transport).currentAccountEmail() == "me@example.com")
    }

    @Test func apiArgEscapesNonAsciiAndDel() throws {
        let header = DropboxArg.header(path: "/Ảnh Tết/đẹp\u{7F}😀.jpg")
        #expect(header.allSatisfy { $0.isASCII && $0.asciiValue! < 0x7F })
        #expect(header == #"{"path":"/\u1ea2nh T\u1ebft/\u0111\u1eb9p\u007f\ud83d\ude00.jpg"}"#)
        let decoded = try JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: String]
        #expect(decoded?["path"] == "/Ảnh Tết/đẹp\u{7F}😀.jpg")
    }

    @Test func downloadSendsEscapedHeaderAndHashesTheBytes() async throws {
        let bytes = Data((0..<5000).map { UInt8($0 % 251) })
        let streamer = StubTransport { _ in StubResponse(status: 200, body: bytes) }
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try await makeClient(transport: streamer).download(path: "/Ảnh/a.jpg", to: dir.appendingPathComponent("a"), control: nil)
        #expect(try Data(contentsOf: file.url) == bytes)
        #expect(file.size == 5000)
        #expect(file.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        #expect(file.md5 == Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let request = try #require(streamer.requests.first)
        #expect(request.headers["Dropbox-API-Arg"]?.contains(#"\u1ea2nh"#) == true)
        #expect(request.url.host == "content.dropboxapi.com")
    }

    @Test func expiredTokenRefreshesOnceThenSucceeds() async throws {
        let tokens = StubTokens()
        let transport = StubTransport { request in
            request.headers["Authorization"] == "Bearer old-token"
                ? .json(401, ["error": [".tag": "expired_access_token"], "error_summary": "expired_access_token/"])
                : .json(["email": "me@example.com"])
        }
        #expect(try await makeClient(tokens: tokens, transport: transport).currentAccountEmail() == "me@example.com")
        #expect(tokens.refreshCount == 1)
        #expect(transport.requests.count == 2)
    }

    @Test func secondUnauthorizedMeansAccessRevoked() async throws {
        let tokens = StubTokens()
        let transport = StubTransport { _ in .json(401, ["error_summary": "invalid_access_token/"]) }
        await #expect(throws: SourceError.accessRevoked) { try await makeClient(tokens: tokens, transport: transport).currentAccountEmail() }
        #expect(tokens.refreshCount == 1)
    }

    @Test func revokedRefreshTokenSurfacesFromTheProvider() async throws {
        let tokens = StubTokens()
        tokens.failRefreshWith = .accessRevoked
        let streamer = StubTransport { _ in StubResponse(status: 401) }
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: SourceError.accessRevoked) {
            try await makeClient(tokens: tokens, transport: streamer).download(path: "/a.jpg", to: dir.appendingPathComponent("a"), control: nil)
        }
    }

    @Test func missingPathMapsToFileMissingAndLeavesNoFile() async throws {
        let streamer = StubTransport { _ in .json(409, ["error_summary": "path/not_found/.."]) }
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("a")
        await #expect(throws: SourceError.fileMissing) { try await makeClient(transport: streamer).download(path: "/a.jpg", to: target, control: nil) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func throttlingWaitsRetryAfterOnceThenRetries() async throws {
        let calls = LockedCounter()
        let transport = StubTransport { _ in
            calls.increment() == 1 ? .json(429, ["error_summary": "too_many_requests/"], headers: ["Retry-After": "2"]) : .json(["email": "e@x.com"])
        }
        #expect(try await makeClient(transport: transport).currentAccountEmail() == "e@x.com")
        #expect(transport.requests.count == 2)
    }

    @Test func longRetryAfterAndServerErrorsAreBusyNotUnavailable() async throws {
        let long = StubTransport { _ in StubResponse(status: 503, headers: ["Retry-After": "600"]) }
        await #expect(throws: SourceError.busy) { try await makeClient(transport: long).currentAccountEmail() }
        #expect(long.requests.count == 1)
        let down = StubTransport { _ in StubResponse(status: 500) }
        await #expect(throws: SourceError.busy) { try await makeClient(transport: down).currentAccountEmail() }
        let limited = StubTransport { _ in StubResponse(status: 429) }
        await #expect(throws: SourceError.busy) { try await makeClient(transport: limited).currentAccountEmail() }
    }

    @Test func aThrottledDownloadIsBusyAndLeavesNoFile() async throws {
        let transport = StubTransport { _ in StubResponse(status: 429, headers: ["Retry-After": "600"]) }
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("a")
        await #expect(throws: SourceError.busy) { try await makeClient(transport: transport).download(path: "id:x", to: target, control: nil) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func transferFailuresAreMappedNotPassedThrough() async throws {
        struct Odd: Error {}
        for (error, expected): (any Error, SourceError) in [
            (URLError(.secureConnectionFailed), .busy), (URLError(.timedOut), .unavailable), (Odd(), .unavailable),
        ] {
            let transport = StubTransport { _ in throw error }
            await #expect(throws: expected) { try await makeClient(transport: transport).currentAccountEmail() }
        }
    }

    @Test func aTokenProviderFailureThatIsNotASourceErrorIsMapped() async throws {
        struct Provider: DropboxAccessTokenProviding {
            func accessToken(forceRefresh: Bool) async throws -> String { throw DropboxAuthError.malformedResponse }
        }
        let client = DropboxClient(tokens: Provider(), transport: StubTransport { _ in .json([:]) }, sleep: { _ in })
        await #expect(throws: SourceError.unavailable) { try await client.currentAccountEmail() }
    }

    @Test func cancellingARealDownloadMidBodyThrowsCancelledAndLeavesNoFile() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingURLProtocol.self]
        let client = makeClient(transport: URLSessionTransport(configuration: configuration))
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("a")
        let task = Task { try await client.download(path: "id:x", to: target, control: nil) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        switch await task.result {
        case .success: Issue.record("a cancelled download must not succeed")
        case .failure(let error): #expect(error as? SourceError == .cancelled, "\(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func networkFailureIsUnavailable() async throws {
        let transport = StubTransport { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: SourceError.unavailable) { try await makeClient(transport: transport).currentAccountEmail() }
    }

    @Test func downloadReportsReceivedBytesToTheProgressSink() async throws {
        let streamer = StubTransport { _ in StubResponse(status: 200, body: Data(repeating: 1, count: 4000)) }
        let seen = Locked<Int64>(0)
        let control = ExportControl()
        control.setProgress(TransferSink { seen.set($0) })
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await makeClient(transport: streamer).download(path: "/a.jpg", to: dir.appendingPathComponent("a"), control: control)
        #expect(seen.value == 4000)
    }

    @Test func cancellationStopsTheDownloadAndRemovesThePartialFile() async throws {
        let streamer = StubTransport { _ in StubResponse(status: 200, body: Data(repeating: 1, count: 4000)) }
        let control = ExportControl(checkpointBytes: 1, checkpoint: { _ in true })
        control.cancel()
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("a")
        await #expect(throws: SourceError.cancelled) { try await makeClient(transport: streamer).download(path: "/a.jpg", to: target, control: control) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
}

private final class Locked<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func set(_ value: T) { lock.withLock { stored = value } }
}
