import CryptoKit
import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultDropbox

/// One transport for both hosts: listing answers come from `entries`, downloads from `files` by id.
final class FakeDropbox: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [[String: Any]] = []
    private var bodies: [String: Data] = [:]
    private var rootGone = false
    private var failure: StubResponse?

    func set(entries: [[String: Any]]) { lock.withLock { self.entries = entries } }
    func set(body: Data, for id: String) { lock.withLock { bodies[id] = body } }
    func setRootGone(_ value: Bool) { lock.withLock { rootGone = value } }
    func failDownloads(with response: StubResponse?) { lock.withLock { failure = response } }

    lazy var transport = StubTransport { [self] request in
        lock.withLock {
            if request.url.host == "content.dropboxapi.com" {
                if let failure { return failure }
                let arg = (try? JSONSerialization.jsonObject(with: Data((request.headers["Dropbox-API-Arg"] ?? "{}").utf8)) as? [String: String])?["path"] ?? ""
                if let body = bodies[arg] { return StubResponse(status: 200, body: body) }
                return .json(409, ["error_summary": "path/not_found/.."])
            }
            if rootGone { return .json(409, ["error_summary": "path/not_found/"]) }
            return .json(["cursor": "c", "has_more": false, "entries": entries])
        }
    }

    var downloads: [RecordedRequest] { transport.requests.filter { $0.url.host == "content.dropboxapi.com" } }
    var listings: [RecordedRequest] { transport.requests.filter { $0.url.host == "api.dropboxapi.com" } }
}

@Suite struct DropboxImportSourceTests {
    private let sourceId = SourceID.folder()

    private func source(_ dropbox: FakeDropbox, root: String = "/Photos", scratch: URL, state: URL) -> DropboxImportSource {
        DropboxImportSource(id: sourceId, rootPath: root, client: makeClient(transport: dropbox.transport),
                            scratchDirectory: scratch, stateDirectory: state, metadata: StubMetadata())
    }

    private func file(_ display: String, id: String, size: Int = 10, downloadable: Bool? = nil) -> [String: Any] {
        var entry: [String: Any] = [".tag": "file", "id": id, "name": (display as NSString).lastPathComponent, "path_display": display,
                                    "path_lower": display.lowercased(), "size": size, "client_modified": "2015-05-12T15:50:38Z",
                                    "server_modified": "2015-05-13T15:50:38Z"]
        if let downloadable { entry["is_downloadable"] = downloadable }
        return entry
    }

    private func folder(_ display: String) -> [String: Any] {
        [".tag": "folder", "id": "id:" + display, "name": (display as NSString).lastPathComponent, "path_display": display, "path_lower": display.lowercased()]
    }

    private func dirs() -> (scratch: URL, state: URL, cleanup: () -> Void) {
        let dir = tempDirectory()
        return (dir.appendingPathComponent("scratch"), dir.appendingPathComponent("state"), { try? FileManager.default.removeItem(at: dir) })
    }

    // MARK: Listing

    @Test func listingIsRelativeToTheRootNormalisedAndFiltered() async throws {
        let decomposed = "Tết".decomposedStringWithCanonicalMapping
        let dropbox = FakeDropbox()
        dropbox.set(entries: [
            folder("/Photos/Trips"),
            file("/photos/Trips/a.JPG", id: "id:1", size: 5),
            file("/Photos/\(decomposed)/b.mov", id: "id:2"),
            file("/Photos/notes.txt", id: "id:3"),
            file("/Photos/.hidden/c.jpg", id: "id:4"),
            file("/Photos/locked.jpg", id: "id:5", downloadable: false),
            file("/Photos/d.xmp", id: "id:6"),
        ])
        let d = dirs()
        defer { d.cleanup() }
        let files = try await source(dropbox, root: "/Photos/", scratch: d.scratch, state: d.state).listFiles()
        #expect(files.map(\.relativePath) == ["Trips/a.JPG", "Tết/b.mov", "d.xmp"].map { $0.precomposedStringWithCanonicalMapping }.sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        })
        let first = try #require(files.first { $0.relativePath == "Trips/a.JPG" })
        #expect(first.sizeBytes == 5 && first.creationDate == Date(timeIntervalSince1970: 1_431_445_838) && first.uti == "public.jpeg")
        #expect(dropbox.listings.first?.json["path"] as? String == "/Photos")
    }

    @Test func folderNamesComeFromTheFolderEntriesSoSiblingsAgreeOnCase() async throws {
        let dropbox = FakeDropbox()
        // Dropbox only promises the case of the last component of path_display, so the parents may differ per entry.
        dropbox.set(entries: [
            folder("/Photos/Trips"), folder("/Photos/Trips/Day 1"),
            file("/photos/trips/day 1/a.heic", id: "id:1"),
            file("/PHOTOS/TRIPS/Day 1/a.mov", id: "id:2"),
            file("/photos/Trips/b.jpg", id: "id:3"),
        ])
        let d = dirs()
        defer { d.cleanup() }
        let paths = try await source(dropbox, scratch: d.scratch, state: d.state).listFiles().map(\.relativePath)
        #expect(paths == ["Trips/Day 1/a.heic", "Trips/Day 1/a.mov", "Trips/b.jpg"])
    }

    @Test func wholeAccountRootIsEmptyPath() async throws {
        let dropbox = FakeDropbox()
        dropbox.set(entries: [file("/a.jpg", id: "id:1")])
        let d = dirs()
        defer { d.cleanup() }
        let files = try await source(dropbox, root: "", scratch: d.scratch, state: d.state).listFiles()
        #expect(files.map(\.relativePath) == ["a.jpg"])
        #expect(dropbox.listings.first?.json["path"] as? String == "")
    }

    @Test func probeFailsAsUnavailableWhenFolderIsGone() async throws {
        let dropbox = FakeDropbox()
        dropbox.setRootGone(true)
        let d = dirs()
        defer { d.cleanup() }
        await #expect(throws: SourceError.unavailable) { try await self.source(dropbox, root: "/x", scratch: d.scratch, state: d.state).probe() }
        dropbox.setRootGone(false)
        try await source(dropbox, root: "/x", scratch: d.scratch, state: d.state).probe()
        #expect(dropbox.listings.last?.json["limit"] as? Int == 1)
    }

    // MARK: Reading

    @Test func inspectDownloadsByIdHashesTheBytesAndCleansTheScratchFile() async throws {
        let bytes = Data("hello dropbox".utf8)
        let dropbox = FakeDropbox()
        dropbox.set(entries: [folder("/Photos/Trips"), file("/Photos/Trips/a.jpg", id: "id:abc")])
        dropbox.set(body: bytes, for: "id:abc")
        let d = dirs()
        defer { d.cleanup() }
        let subject = source(dropbox, scratch: d.scratch, state: d.state)
        _ = try await subject.listFiles()
        let result = try await subject.inspect(relativePath: "Trips/a.jpg", uti: "public.jpeg", mediaType: .image, control: ExportControl())
        #expect(result.size == Int64(bytes.count))
        #expect(result.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        #expect(result.metadata.pixelWidth == 7)
        #expect(try FileManager.default.contentsOfDirectory(atPath: d.scratch.path).isEmpty)
        #expect(try #require(dropbox.downloads.first).headers["Dropbox-API-Arg"] == #"{"path":"id:abc"}"#)
    }

    @Test func aNameInAnotherUnicodeFormStillFindsItsFile() async throws {
        let decomposed = "Ảnh Tết".decomposedStringWithCanonicalMapping
        let dropbox = FakeDropbox()
        dropbox.set(entries: [folder("/Photos/\(decomposed)"), file("/Photos/\(decomposed)/đẹp.jpg", id: "id:vn")])
        dropbox.set(body: Data("vn".utf8), for: "id:vn")
        let d = dirs()
        defer { d.cleanup() }
        let subject = source(dropbox, scratch: d.scratch, state: d.state)
        let path = try #require(try await subject.listFiles().first?.relativePath)
        #expect(path == "Ảnh Tết/đẹp.jpg".precomposedStringWithCanonicalMapping)
        for spelling in [path, path.decomposedStringWithCanonicalMapping] {
            let result = try await subject.inspect(relativePath: spelling, uti: "public.jpeg", mediaType: .image, control: ExportControl())
            #expect(result.size == 2)
        }
    }

    @Test func exportDownloadsTheSiblingOfThePrimaryWithBothHashes() async throws {
        let bytes = Data(repeating: 9, count: 3000)
        let dropbox = FakeDropbox()
        dropbox.set(entries: [folder("/Trips"), file("/Trips/a.heic", id: "id:h"), file("/Trips/a.mov", id: "id:m")])
        dropbox.set(body: bytes, for: "id:m")
        let d = dirs()
        defer { d.cleanup() }
        let subject = source(dropbox, root: "", scratch: d.scratch, state: d.state)
        _ = try await subject.listFiles()
        let locator = ResourceLocator(sourceId: sourceId, localId: ImportLocator(sourceId: sourceId, relativePath: "Trips/a.heic").localId,
                                      type: .pairedVideo, originalFilename: "a.mov")
        let exported = try await subject.exportResource(locator, to: d.scratch.deletingLastPathComponent().appendingPathComponent("out"), control: ExportControl())
        #expect(exported.size == 3000)
        #expect(exported.md5 == Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        #expect(exported.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        #expect(try #require(dropbox.downloads.first).headers["Dropbox-API-Arg"] == #"{"path":"id:m"}"#)
    }

    @Test func foreignLocatorAndEscapingPathsAreMissing() async throws {
        let dropbox = FakeDropbox()
        let d = dirs()
        defer { d.cleanup() }
        let subject = source(dropbox, scratch: d.scratch, state: d.state)
        let foreign = ResourceLocator(sourceId: sourceId, localId: "other/a.jpg", type: .photo, originalFilename: "a.jpg")
        await #expect(throws: SourceError.fileMissing) { try await subject.exportResource(foreign, to: d.scratch.appendingPathComponent("o"), control: ExportControl()) }
        await #expect(throws: SourceError.fileMissing) {
            try await subject.inspect(relativePath: "../secret.jpg", uti: "public.jpeg", mediaType: .image, control: ExportControl())
        }
        #expect(dropbox.downloads.isEmpty)
    }

    @Test func cancelledInspectLeavesNothingBehind() async throws {
        let dropbox = FakeDropbox()
        dropbox.set(entries: [file("/a.jpg", id: "id:1")])
        dropbox.set(body: Data(repeating: 1, count: 100), for: "id:1")
        let d = dirs()
        defer { d.cleanup() }
        let subject = source(dropbox, root: "", scratch: d.scratch, state: d.state)
        _ = try await subject.listFiles()
        let control = ExportControl()
        control.cancel()
        await #expect(throws: SourceError.cancelled) {
            try await subject.inspect(relativePath: "a.jpg", uti: "public.jpeg", mediaType: .image, control: control)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: d.scratch.path).isEmpty)
    }

    // MARK: Stable ids

    @Test func theMapSurvivesARelaunchWithoutAnotherListing() async throws {
        let dropbox = FakeDropbox()
        dropbox.set(entries: [file("/Photos/a.jpg", id: "id:1")])
        dropbox.set(body: Data("one".utf8), for: "id:1")
        let d = dirs()
        defer { d.cleanup() }
        _ = try await source(dropbox, scratch: d.scratch, state: d.state).listFiles()
        let listingsBefore = dropbox.listings.count
        // The file is renamed and a new one takes its name; the saved map still names the original.
        dropbox.set(entries: [file("/Photos/a.jpg", id: "id:2"), file("/Photos/b.jpg", id: "id:1")])
        dropbox.set(body: Data("two".utf8), for: "id:2")
        let relaunched = source(dropbox, scratch: d.scratch, state: d.state)
        let result = try await relaunched.inspect(relativePath: "a.jpg", uti: "public.jpeg", mediaType: .image, control: ExportControl())
        #expect(result.size == 3 && result.sha256 == SHA256.hash(data: Data("one".utf8)).map { String(format: "%02x", $0) }.joined())
        #expect(dropbox.listings.count == listingsBefore)
    }

    @Test func concurrentMissesShareOneListing() async throws {
        let dropbox = FakeDropbox()
        dropbox.set(entries: (1...4).map { file("/Photos/p\($0).jpg", id: "id:\($0)") })
        for i in 1...4 { dropbox.set(body: Data("c\(i)".utf8), for: "id:\(i)") }
        let d = dirs()
        defer { d.cleanup() }
        let fresh = source(dropbox, scratch: d.scratch, state: d.state)
        try await withThrowingTaskGroup(of: Int64.self) { group in
            for i in 1...4 {
                group.addTask { try await fresh.inspect(relativePath: "p\(i).jpg", uti: "public.jpeg", mediaType: .image, control: ExportControl()).size }
            }
            for try await size in group { #expect(size == 2) }
        }
        #expect(dropbox.listings.count == 1)
    }

    // MARK: Failures

    @Test func aMissingFileIsMissingWhileTheRootAnswers() async throws {
        let dropbox = FakeDropbox()
        dropbox.set(entries: [file("/Photos/a.jpg", id: "id:1")])
        let d = dirs()
        defer { d.cleanup() }
        let subject = source(dropbox, scratch: d.scratch, state: d.state)
        _ = try await subject.listFiles()
        await #expect(throws: SourceError.fileMissing) {
            try await subject.inspect(relativePath: "a.jpg", uti: "public.jpeg", mediaType: .image, control: ExportControl())
        }
    }

    @Test func aMissingFileWhileTheRootIsGoneHoldsTheSourceInsteadOfLosingFiles() async throws {
        let dropbox = FakeDropbox()
        dropbox.set(entries: [file("/Photos/a.jpg", id: "id:1")])
        let d = dirs()
        defer { d.cleanup() }
        let subject = source(dropbox, scratch: d.scratch, state: d.state)
        _ = try await subject.listFiles()
        dropbox.setRootGone(true)
        await #expect(throws: SourceError.unavailable) {
            try await subject.inspect(relativePath: "a.jpg", uti: "public.jpeg", mediaType: .image, control: ExportControl())
        }
    }

    @Test func throttledReadsAreBusy() async throws {
        let dropbox = FakeDropbox()
        dropbox.set(entries: [file("/Photos/a.jpg", id: "id:1")])
        let d = dirs()
        defer { d.cleanup() }
        let subject = source(dropbox, scratch: d.scratch, state: d.state)
        _ = try await subject.listFiles()
        for status in [429, 500, 503] {
            dropbox.failDownloads(with: StubResponse(status: status, headers: ["Retry-After": "600"]))
            await #expect(throws: SourceError.busy) {
                try await subject.inspect(relativePath: "a.jpg", uti: "public.jpeg", mediaType: .image, control: ExportControl())
            }
        }
    }

    @Test func aScratchFolderThatCannotBeMadeIsAReadFailure() async throws {
        let dropbox = FakeDropbox()
        dropbox.set(entries: [file("/Photos/a.jpg", id: "id:1")])
        let d = dirs()
        defer { d.cleanup() }
        let subject = source(dropbox, scratch: d.scratch, state: d.state)
        _ = try await subject.listFiles()
        try Data().write(to: d.scratch)
        do { _ = try await subject.inspect(relativePath: "a.jpg", uti: "public.jpeg", mediaType: .image, control: ExportControl()) } catch let error as SourceError {
            guard case .readFailed = error else { Issue.record("wrong error \(error)"); return }
            return
        }
        Issue.record("expected a failure")
    }
}
