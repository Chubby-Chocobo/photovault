import CryptoKit
import Foundation
import Testing
import PhotoVaultCore
@testable import PhotoVaultDrive

let importSourceId = SourceID(rawValue: "folder-" + UUID().uuidString.lowercased())!

struct ImportRig {
    let stub = ImportDriveStub()
    let scratch: URL
    let state: URL
    let keychain = InMemoryKeychainStore()
    let clock = FixedClock()

    init() throws {
        let root = try tempDir()
        scratch = root.appendingPathComponent("scratch")
        state = root.appendingPathComponent("state")
    }

    func auth(_ transport: any HTTPTransport, initial: Bool = true) -> DriveImportAuth {
        let oauth = OAuthClient(config: OAuthConfig(clientID: "c"), transport: transport, clock: clock, openURL: { _ in true })
        return DriveImportAuth(sourceId: importSourceId, oauth: oauth, keychain: keychain, clock: clock,
                               initial: initial ? ("token-1", clock.now.addingTimeInterval(3600)) : nil)
    }

    func source(_ picked: [String], transport: (any HTTPTransport)? = nil, auth override: (any DriveAuthorizing)? = nil) -> DriveImportSource {
        DriveImportSource(id: importSourceId, pickedIds: picked, auth: override ?? auth(transport ?? stub), transport: transport ?? stub,
                          scratchDirectory: scratch, stateDirectory: state, metadata: StubMetadataReader())
    }
}

func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }

@Suite struct DriveImportListingTests {
    @Test func listsTreeWithPagingAndSkips() async throws {
        let rig = try ImportRig()
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

    @Test func readsEveryLevelOfANestedTree() async throws {
        let rig = try ImportRig()
        rig.stub.pageSize = 2
        rig.stub.add(.init(id: "F", name: "Root", mime: DriveMime.folder))
        var parent = "F"
        var expected: [String] = []
        var path = "Root"
        for level in 1...4 {
            let folder = "L\(level)"
            rig.stub.add(.init(id: folder, name: "Level \(level)", mime: DriveMime.folder, parent: parent))
            path += "/Level \(level)"
            for n in 1...3 {
                rig.stub.add(.init(id: "\(folder)-\(n)", name: "p\(n).jpg", parent: folder, content: Data(count: n)))
                expected.append("\(path)/p\(n).jpg")
            }
            parent = folder
        }
        let entries = try await rig.source(["F"]).listFiles()
        #expect(Set(entries.map(\.relativePath)) == Set(expected))
        #expect(entries.count == 12)
    }

    @Test func aFilePickedAndAlsoInsideAPickedFolderIsListedOnce() async throws {
        let rig = try ImportRig()
        rig.stub.add(.init(id: "F", name: "Trip", mime: DriveMime.folder))
        rig.stub.add(.init(id: "A", name: "a.jpg", parent: "F", content: Data(count: 1)))
        rig.stub.add(.init(id: "B", name: "b.jpg", parent: "F", content: Data(count: 2)))
        let entries = try await rig.source(["F", "A"]).listFiles()
        #expect(entries.map(\.relativePath) == ["Trip/a.jpg", "Trip/b.jpg"])
        let reversed = try await rig.source(["A", "F"]).listFiles()
        #expect(reversed.map(\.relativePath) == ["Trip/a.jpg", "Trip/b.jpg"])
    }

    @Test func singlePickedFolderNameOnlyForOneFolder() async throws {
        let rig = try ImportRig()
        rig.stub.add(.init(id: "F", name: " Trip 2024 ", mime: DriveMime.folder))
        rig.stub.add(.init(id: "A", name: "a.jpg"))
        #expect(await rig.source(["F"]).singlePickedFolderName() == "Trip 2024")
        #expect(await rig.source(["A"]).singlePickedFolderName() == nil)
        #expect(await rig.source(["F", "A"]).singlePickedFolderName() == nil)
        #expect(await rig.source(["gone"]).singlePickedFolderName() == nil)
    }

    @Test func duplicateNamesGetDistinctPaths() async throws {
        let rig = try ImportRig()
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
        let rig = try ImportRig()
        rig.stub.add(.init(id: "F", name: "Hidden", mime: DriveMime.folder, hidesChildren: true))
        rig.stub.add(.init(id: "c", name: "x.jpg", parent: "F"))
        #expect(try await rig.source(["F"]).listFiles().isEmpty)
    }

    @Test func deletedPickIsSkippedAndProbeStillSucceeds() async throws {
        let rig = try ImportRig()
        rig.stub.add(.init(id: "A", name: "a.jpg"))
        let source = rig.source(["gone", "A"])
        try await source.probe()
        #expect(try await source.listFiles().map(\.relativePath) == ["a.jpg"])
    }

    @Test func unsafeNamesStayInsideTheRoot() async throws {
        let rig = try ImportRig()
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
        let rig = try ImportRig()
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
        let locator = ResourceLocator(sourceId: importSourceId, localId: ImportLocator(sourceId: importSourceId, relativePath: "big.jpg").localId,
                                      type: .photo, originalFilename: "big.jpg")
        let exported = try await source.exportResource(locator, to: dest, control: ExportControl())
        #expect(exported.size == Int64(bytes.count) && exported.sha256 == sha(bytes) && exported.md5 == md5(bytes))
        #expect(try Data(contentsOf: dest) == bytes)
    }

    @Test func exportUsesTheSiblingNameInTheSameFolder() async throws {
        let rig = try ImportRig()
        rig.stub.add(.init(id: "F", name: "D", mime: DriveMime.folder))
        rig.stub.add(.init(id: "A", name: "a.jpg", parent: "F", content: Data("one".utf8)))
        rig.stub.add(.init(id: "B", name: "a.mov", mime: "video/quicktime", parent: "F", content: Data("two".utf8)))
        let source = rig.source(["F"])
        _ = try await source.listFiles()
        let primary = ImportLocator(sourceId: importSourceId, relativePath: "D/a.jpg").localId
        let dest = try tempDir().appendingPathComponent("o")
        let file = try await source.exportResource(.init(sourceId: importSourceId, localId: primary, type: .pairedVideo, originalFilename: "a.mov"),
                                                   to: dest, control: ExportControl())
        #expect(file.sha256 == sha(Data("two".utf8)))
    }

    @Test func relistsLazilyAfterRelaunch() async throws {
        let rig = try ImportRig()
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
        let rig = try ImportRig()
        rig.stub.add(.init(id: "A", name: "a.jpg"))
        let source = rig.source(["A"])
        _ = try await source.listFiles()
        rig.stub.remove("A")
        await #expect(throws: SourceError.fileMissing) {
            try await source.inspect(relativePath: "a.jpg", uti: "public.jpeg", mediaType: .image, control: ExportControl())
        }
    }

    @Test func cancellationStopsTheDownloadAndLeavesNoFile() async throws {
        let rig = try ImportRig()
        rig.stub.add(.init(id: "A", name: "a.jpg", content: Data(count: 4_000_000)))
        let source = rig.source(["A"])
        _ = try await source.listFiles()
        let control = ExportControl(checkpointBytes: 1, checkpoint: { _ in false })
        let dest = try tempDir().appendingPathComponent("o")
        let locator = ResourceLocator(sourceId: importSourceId, localId: ImportLocator(sourceId: importSourceId, relativePath: "a.jpg").localId,
                                      type: .photo, originalFilename: "a.jpg")
        await #expect(throws: SourceError.cancelled) { try await source.exportResource(locator, to: dest, control: control) }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func serverErrorsMapToSourceErrors() async throws {
        let rig = try ImportRig()
        rig.stub.add(.init(id: "A", name: "a.jpg"))
        let source = rig.source(["A"])
        _ = try await source.listFiles()
        let cases: [(StubResponse, SourceError)] = [
            (.json(429, [:]), .busy), (.json(503, [:]), .busy), (.json(500, [:]), .busy),
            (.json(403, ["error": ["errors": [["reason": "downloadQuotaExceeded"]]]]), .busy),
            (.json(403, ["error": ["errors": [["reason": "userRateLimitExceeded"]]]]), .busy),
            (.json(403, ["error": ["errors": [["reason": "rateLimitExceeded"]]]]), .busy),
        ]
        for (response, expected) in cases {
            rig.stub.fail("A", with: response)
            await #expect(throws: expected) {
                try await source.inspect(relativePath: "a.jpg", uti: "public.jpeg", mediaType: .image, control: ExportControl())
            }
        }
    }

    @Test func networkFailureIsUnavailable() async throws {
        let rig = try ImportRig()
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
        let rig = try ImportRig()
        rig.stub.add(.init(id: "A", name: "a.jpg", content: Data("abc".utf8)))
        try DriveImportAuth.store(refreshToken: "r-1", for: importSourceId, in: rig.keychain)
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
        let rig = try ImportRig()
        try DriveImportAuth.store(refreshToken: "dead", for: importSourceId, in: rig.keychain)
        rig.stub.validToken.value = "other"
        let router = RouterTransport(oauth: StubTransport { _ in .json(400, ["error": "invalid_grant"]) }, drive: rig.stub)
        let source = rig.source(["A"], transport: router)
        await #expect(throws: SourceError.accessRevoked) { try await source.probe() }
    }

    @Test func missingGrantIsAccessRevoked() async throws {
        let rig = try ImportRig()
        let router = RouterTransport(oauth: StubTransport { _ in .json(500, [:]) }, drive: rig.stub)
        let source = rig.source(["A"], transport: router, auth: rig.auth(router, initial: false))
        await #expect(throws: SourceError.accessRevoked) { try await source.probe() }
        #expect(try rig.keychain.read(account: CloudTokenAccount.importGrant(importSourceId)) == nil)
    }

    @Test func grantLivesUnderThePerImportAccount() throws {
        let keychain = InMemoryKeychainStore()
        try DriveImportAuth.store(refreshToken: "r", for: importSourceId, in: keychain)
        #expect(try keychain.read(account: "import-" + importSourceId.rawValue) == Data("r".utf8))
        try DriveImportAuth.removeGrant(for: importSourceId, from: keychain)
        #expect(try keychain.read(account: "import-" + importSourceId.rawValue) == nil)
    }

    @Test func rotatedRefreshTokenIsStored() async throws {
        let rig = try ImportRig()
        try DriveImportAuth.store(refreshToken: "r-1", for: importSourceId, in: rig.keychain)
        let oauth = StubTransport { _ in .json(200, ["access_token": "t2", "refresh_token": "r-2", "expires_in": 3600]) }
        let auth = rig.auth(oauth, initial: false)
        #expect(try await auth.accessToken() == "t2")
        #expect(try rig.keychain.read(account: CloudTokenAccount.importGrant(importSourceId)) == Data("r-2".utf8))
    }
}

@Suite struct DriveImportLocationTests {
    @Test func theSourceWalksParentsWithMetadataRequestsOnly() async throws {
        let rig = try ImportRig()
        rig.stub.add(.init(id: "R", name: "My Drive", mime: DriveMime.folder, isRoot: true))
        rig.stub.add(.init(id: "T", name: "Trips", mime: DriveMime.folder, parent: "R"))
        rig.stub.add(.init(id: "Y", name: "2024", mime: DriveMime.folder, parent: "T"))
        let result = await rig.source(["Y"]).pickedLocations()
        #expect(result?.paths == ["My Drive/Trips/2024"])
        #expect(result?.webURL == "https://drive.google.com/drive/folders/Y")
        #expect(rig.stub.requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(rig.stub.listingRequests == 0)
    }

    @Test func aServerErrorKeepsTheNameOnly() async throws {
        let rig = try ImportRig()
        rig.stub.add(.init(id: "R", name: "My Drive", mime: DriveMime.folder, isRoot: true))
        rig.stub.add(.init(id: "Y", name: "2024", mime: DriveMime.folder, parent: "R"))
        rig.stub.fail("R", with: .json(500, [:]))
        #expect(await rig.source(["Y"]).pickedLocations() == nil)
    }

    /// The Drive call is held until the test says so, so no bound on the clock decides the result: the lookup
    /// gives up (nil) while the call is still unanswered, and a hang would be stopped by the time limit.
    @Test(.timeLimit(.minutes(1))) func aSlowDriveDoesNotHoldTheImportBack() async throws {
        let rig = try ImportRig()
        rig.stub.add(.init(id: "R", name: "My Drive", mime: DriveMime.folder, isRoot: true))
        rig.stub.add(.init(id: "Y", name: "2024", mime: DriveMime.folder, parent: "R"))
        rig.stub.holdAnswers()
        defer { rig.stub.releaseAnswers() }
        #expect(await rig.source(["Y"]).pickedLocations(timeout: .milliseconds(50)) == nil)
        #expect(rig.stub.requests.count >= 1, "the lookup did ask Drive")
        #expect(rig.stub.answered == 0, "and gave up while Drive had not answered")
    }
}
