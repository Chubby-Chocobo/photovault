import CryptoKit
import Foundation
import Testing
import PhotoVaultCore
@testable import PhotoVaultDrive

private let sourceId = SourceID(rawValue: "folder-" + UUID().uuidString.lowercased())!

private struct Rig {
    let stub = ImportDriveStub()
    let scratch: URL
    let keychain = InMemoryKeychainStore()
    let clock = FixedClock()

    init() throws { scratch = try tempDir().appendingPathComponent("scratch") }

    func auth(_ transport: any HTTPTransport, initial: Bool = true) -> DriveImportAuth {
        let oauth = OAuthClient(config: OAuthConfig(clientID: "c"), transport: transport, clock: clock, openURL: { _ in true })
        return DriveImportAuth(sourceId: sourceId, oauth: oauth, keychain: keychain, clock: clock,
                               initial: initial ? ("token-1", clock.now.addingTimeInterval(3600)) : nil)
    }

    func source(_ picked: [String], transport: (any HTTPTransport)? = nil, auth override: (any DriveAuthorizing)? = nil) -> DriveImportSource {
        DriveImportSource(id: sourceId, pickedIds: picked, auth: override ?? auth(transport ?? stub), transport: transport ?? stub,
                          scratchDirectory: scratch, metadata: StubMetadataReader())
    }
}

private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }

@Suite struct DriveImportListingTests {
    @Test func listsTreeWithPagingAndSkips() async throws {
        let rig = try Rig()
        rig.stub.pageSize = 2
        rig.stub.add(.init(id: "F", name: "Trip", mime: DriveMime.folder))
        for i in 1...5 { rig.stub.add(.init(id: "a\(i)", name: "p\(i).jpg", parent: "F", content: Data(count: i))) }
        rig.stub.add(.init(id: "doc", name: "notes", mime: "application/vnd.google-apps.document", parent: "F"))
        rig.stub.add(.init(id: "sc", name: "link.jpg", mime: DriveMime.shortcut, parent: "F"))
        rig.stub.add(.init(id: "pv", name: "mine.jpg", parent: "F", props: ["pvSchema": "1"]))
        rig.stub.add(.init(id: "tr", name: "old.jpg", parent: "F", trashed: true))
        rig.stub.add(.init(id: "sub", name: "Day 2", mime: DriveMime.folder, parent: "F"))
        rig.stub.add(.init(id: "b1", name: "v.mov", mime: "video/quicktime", parent: "sub", content: Data(count: 9)))
        rig.stub.add(.init(id: "txt", name: "readme.txt", mime: "text/plain", parent: "F"))
        rig.stub.add(.init(id: "R", name: "root.png", mime: "image/png", content: Data(count: 3)))
        let entries = try await rig.source(["F", "R"]).listFiles()
        #expect(entries.map(\.relativePath) == ["Trip/Day 2/v.mov", "Trip/p1.jpg", "Trip/p2.jpg", "Trip/p3.jpg", "Trip/p4.jpg", "Trip/p5.jpg", "root.png"])
        #expect(entries.first { $0.relativePath == "root.png" }?.sizeBytes == 3)
        #expect(entries.first?.creationDate != nil && entries.first?.modificationDate != nil)
        #expect(entries.first?.uti == "com.apple.quicktime-movie")
    }

    @Test func duplicateNamesGetDistinctPaths() async throws {
        let rig = try Rig()
        rig.stub.add(.init(id: "F", name: "Dir", mime: DriveMime.folder))
        rig.stub.add(.init(id: "z", name: "IMG.jpg", parent: "F"))
        rig.stub.add(.init(id: "a", name: "IMG.jpg", parent: "F"))
        rig.stub.add(.init(id: "m", name: "img.JPG", parent: "F"))
        let paths = try await rig.source(["F"]).listFiles().map(\.relativePath)
        #expect(Set(paths) == ["Dir/IMG.jpg", "Dir/img (2).JPG", "Dir/IMG (3).jpg"])
        let again = try await rig.source(["F"]).listFiles().map(\.relativePath)
        #expect(again == paths)
    }

    @Test func pickedFolderWithNoReadableChildrenIsEmptyNotAnError() async throws {
        let rig = try Rig()
        rig.stub.add(.init(id: "F", name: "Hidden", mime: DriveMime.folder, hidesChildren: true))
        rig.stub.add(.init(id: "c", name: "x.jpg", parent: "F"))
        #expect(try await rig.source(["F"]).listFiles().isEmpty)
    }

    @Test func deletedPickIsSkippedAndProbeStillSucceeds() async throws {
        let rig = try Rig()
        rig.stub.add(.init(id: "A", name: "a.jpg"))
        let source = rig.source(["gone", "A"])
        try await source.probe()
        #expect(try await source.listFiles().map(\.relativePath) == ["a.jpg"])
    }

    @Test func unsafeNamesStayInsideTheRoot() async throws {
        let rig = try Rig()
        rig.stub.add(.init(id: "A", name: "../evil/a.jpg"))
        rig.stub.add(.init(id: "B", name: "..", mime: DriveMime.folder))
        rig.stub.add(.init(id: "c", name: "ok.jpg", parent: "B"))
        let paths = try await rig.source(["A", "B"]).listFiles().map(\.relativePath)
        #expect(paths.allSatisfy { !$0.split(separator: "/").contains("..") })
        #expect(paths.count == 2)
    }
}

@Suite struct DriveImportTransferTests {
    @Test func inspectAndExportHashesMatchTheBytes() async throws {
        let rig = try Rig()
        let bytes = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        rig.stub.add(.init(id: "A", name: "big.jpg", content: bytes))
        let source = rig.source(["A"])
        _ = try await source.listFiles()
        let inspected = try await source.inspect(relativePath: "big.jpg", uti: "public.jpeg", mediaType: .image, control: ExportControl())
        #expect(inspected.size == Int64(bytes.count) && inspected.sha256 == sha(bytes))
        #expect(inspected.metadata.pixelWidth == bytes.count)
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.scratch.path).isEmpty)

        let dir = try tempDir()
        let dest = dir.appendingPathComponent("out.jpg")
        let locator = ResourceLocator(sourceId: sourceId, localId: ImportLocator(sourceId: sourceId, relativePath: "big.jpg").localId,
                                      type: .photo, originalFilename: "big.jpg")
        let exported = try await source.exportResource(locator, to: dest, control: ExportControl())
        #expect(exported.size == Int64(bytes.count) && exported.sha256 == sha(bytes) && exported.md5 == md5(bytes))
        #expect(try Data(contentsOf: dest) == bytes)
    }

    @Test func exportUsesTheSiblingNameInTheSameFolder() async throws {
        let rig = try Rig()
        rig.stub.add(.init(id: "F", name: "D", mime: DriveMime.folder))
        rig.stub.add(.init(id: "A", name: "a.jpg", parent: "F", content: Data("one".utf8)))
        rig.stub.add(.init(id: "B", name: "a.mov", mime: "video/quicktime", parent: "F", content: Data("two".utf8)))
        let source = rig.source(["F"])
        _ = try await source.listFiles()
        let primary = ImportLocator(sourceId: sourceId, relativePath: "D/a.jpg").localId
        let dest = try tempDir().appendingPathComponent("o")
        let file = try await source.exportResource(.init(sourceId: sourceId, localId: primary, type: .pairedVideo, originalFilename: "a.mov"),
                                                   to: dest, control: ExportControl())
        #expect(file.sha256 == sha(Data("two".utf8)))
    }

    @Test func relistsLazilyAfterRelaunch() async throws {
        let rig = try Rig()
        rig.stub.add(.init(id: "F", name: "D", mime: DriveMime.folder))
        rig.stub.add(.init(id: "A", name: "a.jpg", parent: "F", content: Data("x".utf8)))
        let fresh = rig.source(["F"])
        #expect(rig.stub.listingRequests == 0)
        let inspected = try await fresh.inspect(relativePath: "D/a.jpg", uti: "public.jpeg", mediaType: .image, control: ExportControl())
        #expect(inspected.sha256 == sha(Data("x".utf8)) && rig.stub.listingRequests == 1)
        await #expect(throws: SourceError.fileMissing) {
            try await fresh.inspect(relativePath: "D/nope.jpg", uti: "public.jpeg", mediaType: .image, control: ExportControl())
        }
        #expect(rig.stub.listingRequests == 1)
    }

    @Test func missingFileMapsToFileMissing() async throws {
        let rig = try Rig()
        rig.stub.add(.init(id: "A", name: "a.jpg"))
        let source = rig.source(["A"])
        _ = try await source.listFiles()
        rig.stub.remove("A")
        await #expect(throws: SourceError.fileMissing) {
            try await source.inspect(relativePath: "a.jpg", uti: "public.jpeg", mediaType: .image, control: ExportControl())
        }
    }

    @Test func cancellationStopsTheDownloadAndLeavesNoFile() async throws {
        let rig = try Rig()
        rig.stub.add(.init(id: "A", name: "a.jpg", content: Data(count: 4_000_000)))
        let source = rig.source(["A"])
        _ = try await source.listFiles()
        let control = ExportControl(checkpointBytes: 1, checkpoint: { _ in false })
        let dest = try tempDir().appendingPathComponent("o")
        let locator = ResourceLocator(sourceId: sourceId, localId: ImportLocator(sourceId: sourceId, relativePath: "a.jpg").localId,
                                      type: .photo, originalFilename: "a.jpg")
        await #expect(throws: SourceError.cancelled) { try await source.exportResource(locator, to: dest, control: control) }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func serverErrorsMapToSourceErrors() async throws {
        let rig = try Rig()
        rig.stub.add(.init(id: "A", name: "a.jpg"))
        let source = rig.source(["A"])
        _ = try await source.listFiles()
        let cases: [(StubResponse, SourceError)] = [
            (.json(429, [:]), .unavailable), (.json(503, [:]), .unavailable),
            (.json(403, ["error": ["errors": [["reason": "downloadQuotaExceeded"]]]]), .readFailed(code: 403)),
            (.json(403, ["error": ["errors": [["reason": "userRateLimitExceeded"]]]]), .unavailable),
        ]
        for (response, expected) in cases {
            rig.stub.fail("A", with: response)
            await #expect(throws: expected) {
                try await source.inspect(relativePath: "a.jpg", uti: "public.jpeg", mediaType: .image, control: ExportControl())
            }
        }
    }

    @Test func networkFailureIsUnavailable() async throws {
        let rig = try Rig()
        let down = StubTransport { _ in throw URLError(.notConnectedToInternet) }
        let source = rig.source(["A"], transport: down, auth: FixedTokenAuth(token: "t"))
        await #expect(throws: SourceError.unavailable) { try await source.probe() }
        await #expect(throws: SourceError.unavailable) { _ = try await source.listFiles() }
    }
}

@Suite struct DriveImportAuthTests {
    private func tokenResponse(_ token: String) -> StubResponse {
        .json(200, ["access_token": token, "expires_in": 3600, "scope": "https://www.googleapis.com/auth/drive.file"])
    }

    @Test func refreshesOnUnauthorizedAndRetries() async throws {
        let rig = try Rig()
        rig.stub.add(.init(id: "A", name: "a.jpg", content: Data("abc".utf8)))
        try DriveImportAuth.store(refreshToken: "r-1", for: sourceId, in: rig.keychain)
        rig.stub.validToken.value = "token-2"
        let oauth = StubTransport { [self] _ in tokenResponse("token-2") }
        let router = RouterTransport(oauth: oauth, drive: rig.stub)
        let source = rig.source(["A"], transport: router)
        _ = try await source.listFiles()
        let info = try await source.inspect(relativePath: "a.jpg", uti: "public.jpeg", mediaType: .image, control: ExportControl())
        #expect(info.sha256 == sha(Data("abc".utf8)))
        #expect(oauth.requests.count == 1 && oauth.requests[0].form["refresh_token"] == "r-1")
    }

    @Test func invalidGrantIsAccessRevoked() async throws {
        let rig = try Rig()
        try DriveImportAuth.store(refreshToken: "dead", for: sourceId, in: rig.keychain)
        rig.stub.validToken.value = "other"
        let router = RouterTransport(oauth: StubTransport { _ in .json(400, ["error": "invalid_grant"]) }, drive: rig.stub)
        let source = rig.source(["A"], transport: router)
        await #expect(throws: SourceError.accessRevoked) { try await source.probe() }
    }

    @Test func missingGrantIsAccessRevoked() async throws {
        let rig = try Rig()
        let router = RouterTransport(oauth: StubTransport { _ in .json(500, [:]) }, drive: rig.stub)
        let source = rig.source(["A"], transport: router, auth: rig.auth(router, initial: false))
        await #expect(throws: SourceError.accessRevoked) { try await source.probe() }
        #expect(!DriveImportAuth.hasGrant(for: sourceId, in: rig.keychain))
    }

    @Test func grantLivesUnderThePerImportAccount() throws {
        let keychain = InMemoryKeychainStore()
        try DriveImportAuth.store(refreshToken: "r", for: sourceId, in: keychain)
        #expect(try keychain.read(account: "import-" + sourceId.rawValue) == Data("r".utf8))
        #expect(DriveImportAuth.hasGrant(for: sourceId, in: keychain))
        try DriveImportAuth.removeGrant(for: sourceId, from: keychain)
        #expect(!DriveImportAuth.hasGrant(for: sourceId, in: keychain))
    }

    @Test func rotatedRefreshTokenIsStored() async throws {
        let rig = try Rig()
        try DriveImportAuth.store(refreshToken: "r-1", for: sourceId, in: rig.keychain)
        let oauth = StubTransport { _ in .json(200, ["access_token": "t2", "refresh_token": "r-2", "expires_in": 3600]) }
        let auth = rig.auth(oauth, initial: false)
        #expect(try await auth.accessToken() == "t2")
        #expect(try rig.keychain.read(account: DriveImportAuth.keychainAccount(for: sourceId)) == Data("r-2".utf8))
    }
}
