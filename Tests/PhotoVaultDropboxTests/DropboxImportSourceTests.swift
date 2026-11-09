import CryptoKit
import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultDropbox

@Suite struct DropboxImportSourceTests {
    private let sourceId = SourceID.folder()

    private func source(root: String, transport: StubTransport = StubTransport { _ in .json([:]) },
                        streamer: StubStreamer = StubStreamer { _ in StubResponse(status: 200) }, scratch: URL) -> DropboxImportSource {
        DropboxImportSource(id: sourceId, rootPath: root, client: makeClient(transport: transport, streamer: streamer),
                            scratchDirectory: scratch, metadata: StubMetadata())
    }

    private func file(_ display: String, size: Int = 10, downloadable: Bool? = nil) -> [String: Any] {
        var entry: [String: Any] = [".tag": "file", "name": (display as NSString).lastPathComponent, "path_display": display,
                                    "size": size, "client_modified": "2015-05-12T15:50:38Z", "server_modified": "2015-05-13T15:50:38Z"]
        if let downloadable { entry["is_downloadable"] = downloadable }
        return entry
    }

    @Test func listingIsRelativeToTheRootNormalisedAndFiltered() async throws {
        let decomposed = "Tết".decomposedStringWithCanonicalMapping
        let transport = StubTransport { _ in
            .json(["cursor": "c", "has_more": false, "entries": [
                [".tag": "folder", "name": "Trips", "path_display": "/Photos/Trips"],
                self.file("/photos/Trips/a.JPG", size: 5),
                self.file("/Photos/\(decomposed)/b.mov"),
                self.file("/Photos/notes.txt"),
                self.file("/Photos/.hidden/c.jpg"),
                self.file("/Photos/locked.jpg", downloadable: false),
                self.file("/Photos/d.xmp"),
            ]])
        }
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try await source(root: "/Photos/", transport: transport, scratch: dir).listFiles()
        #expect(files.map(\.relativePath) == ["Trips/a.JPG", "Tết/b.mov", "d.xmp"].map { $0.precomposedStringWithCanonicalMapping }.sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        })
        let first = try #require(files.first { $0.relativePath == "Trips/a.JPG" })
        #expect(first.sizeBytes == 5)
        #expect(first.creationDate == Date(timeIntervalSince1970: 1_431_445_838))
        #expect(first.uti == "public.jpeg")
        #expect(transport.requests.first?.json["path"] as? String == "/Photos")
    }

    @Test func wholeAccountRootIsEmptyPath() async throws {
        let transport = StubTransport { _ in .json(["cursor": "c", "has_more": false, "entries": [self.file("/a.jpg")]]) }
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try await source(root: "", transport: transport, scratch: dir).listFiles()
        #expect(files.map(\.relativePath) == ["a.jpg"])
        #expect(transport.requests.first?.json["path"] as? String == "")
    }

    @Test func probeFailsAsUnavailableWhenFolderIsGone() async throws {
        let gone = StubTransport { _ in .json(409, ["error_summary": "path/not_found/"]) }
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: SourceError.unavailable) { try await self.source(root: "/x", transport: gone, scratch: dir).probe() }
        let ok = StubTransport { _ in .json(["cursor": "c", "has_more": true, "entries": []]) }
        try await source(root: "/x", transport: ok, scratch: dir).probe()
        #expect(ok.requests.count == 1)
        #expect(ok.requests.first?.json["limit"] as? Int == 1)
    }

    @Test func inspectHashesTheBytesAndCleansTheScratchFile() async throws {
        let bytes = Data("hello dropbox".utf8)
        let streamer = StubStreamer { _ in StubResponse(status: 200, body: bytes) }
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scratch = dir.appendingPathComponent("scratch")
        let result = try await source(root: "/Photos", streamer: streamer, scratch: scratch)
            .inspect(relativePath: "Trips/a.jpg", uti: "public.jpeg", mediaType: .image, control: ExportControl())
        #expect(result.size == Int64(bytes.count))
        #expect(result.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        #expect(result.metadata.pixelWidth == 7)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        #expect(try #require(streamer.requests.first).headers["Dropbox-API-Arg"] == #"{"path":"/Photos/Trips/a.jpg"}"#)
    }

    @Test func exportDownloadsTheSiblingOfThePrimaryWithBothHashes() async throws {
        let bytes = Data(repeating: 9, count: 3000)
        let streamer = StubStreamer { _ in StubResponse(status: 200, body: bytes) }
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let locator = ResourceLocator(sourceId: sourceId, localId: ImportLocator(sourceId: sourceId, relativePath: "Trips/a.heic").localId,
                                      type: .pairedVideo, originalFilename: "a.mov")
        let exported = try await source(root: "", streamer: streamer, scratch: dir)
            .exportResource(locator, to: dir.appendingPathComponent("out"), control: ExportControl())
        #expect(exported.size == 3000)
        #expect(exported.md5 == Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        #expect(exported.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        #expect(try #require(streamer.requests.first).headers["Dropbox-API-Arg"] == #"{"path":"/Trips/a.mov"}"#)
    }

    @Test func foreignLocatorAndEscapingPathsAreMissing() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let subject = source(root: "/Photos", scratch: dir)
        let foreign = ResourceLocator(sourceId: sourceId, localId: "other/a.jpg", type: .photo, originalFilename: "a.jpg")
        await #expect(throws: SourceError.fileMissing) { try await subject.exportResource(foreign, to: dir.appendingPathComponent("o"), control: ExportControl()) }
        await #expect(throws: SourceError.fileMissing) {
            try await subject.inspect(relativePath: "../secret.jpg", uti: "public.jpeg", mediaType: .image, control: ExportControl())
        }
    }

    @Test func cancelledInspectLeavesNothingBehind() async throws {
        let streamer = StubStreamer { _ in StubResponse(status: 200, body: Data(repeating: 1, count: 100)) }
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let control = ExportControl()
        control.cancel()
        await #expect(throws: SourceError.cancelled) {
            try await self.source(root: "", streamer: streamer, scratch: dir)
                .inspect(relativePath: "a.jpg", uti: "public.jpeg", mediaType: .image, control: control)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}
