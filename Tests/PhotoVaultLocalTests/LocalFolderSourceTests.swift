import CryptoKit
import Foundation
import PhotoVaultCore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultLocal

private struct StubMetadata: FileMetadataReading {
    func fileMetadata(of file: URL, uti: String, mediaType: MediaType) -> FileMetadata {
        FileMetadata(capture: CaptureMetadata(make: file.lastPathComponent), pixelWidth: 3, pixelHeight: 2)
    }
}

@Suite struct LocalFolderSourceTests {
    let base: URL
    let root: URL
    let sourceId = SourceID.folder()

    init() throws {
        base = try TestFiles.temporaryDirectory("pv-source").resolvingSymlinksInPath()
        root = base.appendingPathComponent("pick", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func source(_ url: URL? = nil) -> LocalFolderSource {
        LocalFolderSource(id: sourceId, root: PlainURLRoot(url ?? root), metadata: StubMetadata())
    }

    @discardableResult
    func write(_ relative: String, _ bytes: Data = Data("x".utf8)) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    @Test func listingSkipsHiddenFilesPackagesAndSymlinks() async throws {
        try write("a.jpg")
        try write("trip/day1/IMG_1.HEIC")
        try write("trip/day1/IMG_1.MOV")
        try write("trip/IMG_1.AAE")
        try write("raw/DSC1.ARW")
        try write("notes.txt")
        try write(".hidden.jpg")
        try write(".Trash/old.jpg")
        try write("Lib.photoslibrary/originals/0/X.jpg")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.jpg"), withDestinationURL: root.appendingPathComponent("a.jpg"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linkdir"), withDestinationURL: root.appendingPathComponent("trip"))
        let entries = try await source().listFiles()
        #expect(entries.map(\.relativePath) == ["a.jpg", "raw/DSC1.ARW", "trip/IMG_1.AAE", "trip/day1/IMG_1.HEIC", "trip/day1/IMG_1.MOV"])
        let heic = try #require(entries.first { $0.relativePath.hasSuffix(".HEIC") })
        #expect(heic.uti == "public.heic" && heic.sizeBytes == 1 && heic.modificationDate != nil)
        #expect(FolderItemGrouper.isIgnored(relativePath: "trip/IMG_1.AAE"))
    }

    @Test func listingNormalisesNamesToNFC() async throws {
        try write("Ha\u{0300}/a.jpg")
        let entries = try await source().listFiles()
        #expect(entries.map(\.relativePath) == ["H\u{00E0}/a.jpg"])
    }

    @Test func inspectHashesAndReadsMetadata() async throws {
        let data = Data((0..<3_000_000).map { UInt8($0 % 251) })
        try write("d/a.jpg", data)
        let result = try await source().inspect(relativePath: "d/a.jpg", uti: "public.jpeg", mediaType: .image, control: ExportControl())
        #expect(result.size == Int64(data.count) && result.sha256 == sha(data))
        #expect(result.metadata.capture.make == "a.jpg" && result.metadata.pixelWidth == 3)
    }

    @Test func exportCopyHasTheSameHashes() async throws {
        let data = Data((0..<2_500_000).map { UInt8($0 % 241) })
        try write("d/a.heic", data)
        let primary = ImportLocator(sourceId: sourceId, relativePath: "d/a.heic")
        let target = base.appendingPathComponent("staging/out")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try await source().exportResource(
            ResourceLocator(sourceId: sourceId, localId: primary.localId, type: .photo, originalFilename: "a.heic"), to: target, control: ExportControl())
        #expect(file.size == Int64(data.count) && file.sha256 == sha(data))
        #expect(file.md5 == TestFiles.hashes(of: data).md5)
        #expect(try Data(contentsOf: target) == data)
    }

    @Test func exportOfASiblingUsesThePrimaryDirectory() async throws {
        try write("d/a.heic", Data("img".utf8))
        try write("d/a.mov", Data("vid".utf8))
        let primary = ImportLocator(sourceId: sourceId, relativePath: "d/a.heic")
        let target = base.appendingPathComponent("out")
        let file = try await source().exportResource(
            ResourceLocator(sourceId: sourceId, localId: primary.localId, type: .pairedVideo, originalFilename: "a.mov"), to: target, control: ExportControl())
        #expect(try Data(contentsOf: target) == Data("vid".utf8) && file.size == 3)
    }

    @Test func cancelStopsAtTheFirstCheckpointAndLeavesNoFile() async throws {
        try write("a.jpg", Data(repeating: 1, count: 3_000_000))
        let primary = ImportLocator(sourceId: sourceId, relativePath: "a.jpg")
        let target = base.appendingPathComponent("out")
        let control = ExportControl(checkpointBytes: 1) { _ in false }
        await #expect(throws: SourceError.cancelled) {
            try await source().exportResource(
                ResourceLocator(sourceId: sourceId, localId: primary.localId, type: .photo, originalFilename: "a.jpg"), to: target, control: control)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        let inspectControl = ExportControl(checkpointBytes: 1) { _ in false }
        await #expect(throws: SourceError.cancelled) {
            try await source().inspect(relativePath: "a.jpg", uti: "public.jpeg", mediaType: .image, control: inspectControl)
        }
    }

    @Test func missingFilesAndMissingRoot() async throws {
        try write("a.jpg")
        let primary = ImportLocator(sourceId: sourceId, relativePath: "a.jpg")
        let sut = source()
        await #expect(throws: SourceError.fileMissing) {
            try await sut.inspect(relativePath: "nope.jpg", uti: "public.jpeg", mediaType: .image, control: ExportControl())
        }
        await #expect(throws: SourceError.fileMissing) {
            try await sut.exportResource(ResourceLocator(sourceId: sourceId, localId: primary.localId, type: .photo, originalFilename: "gone.jpg"),
                                         to: base.appendingPathComponent("o"), control: ExportControl())
        }
        await #expect(throws: SourceError.fileMissing) {
            try await sut.inspect(relativePath: "../x.jpg", uti: "public.jpeg", mediaType: .image, control: ExportControl())
        }
        try await sut.probe()
        try FileManager.default.removeItem(at: root)
        await #expect(throws: SourceError.unavailable) { try await sut.probe() }
        await #expect(throws: SourceError.unavailable) { try await sut.listFiles() }
        await #expect(throws: SourceError.unavailable) {
            try await sut.inspect(relativePath: "a.jpg", uti: "public.jpeg", mediaType: .image, control: ExportControl())
        }
    }

    @Test func aRootThatFailsToOpenIsUnavailable() async throws {
        struct Broken: RootAccess {
            func withRoot<T>(_ body: (URL) throws -> T) throws -> T { throw DestinationError.bookmarkInvalid }
        }
        let sut = LocalFolderSource(id: sourceId, root: Broken(), metadata: StubMetadata())
        await #expect(throws: SourceError.unavailable) { try await sut.probe() }
    }

    @Test func nothingIsWrittenInsideTheFolder() async throws {
        try write("d/a.jpg")
        try write("d/a.mov")
        func snapshot() throws -> [String] {
            let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])!
            return try walker.compactMap { ($0 as? URL) }.map { url in
                "\(url.path)|\(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!.timeIntervalSince1970)"
            }.sorted() + ["root|\(try root.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!.timeIntervalSince1970)"]
        }
        let before = try snapshot()
        let sut = source()
        try await sut.probe()
        _ = try await sut.listFiles()
        _ = try await sut.inspect(relativePath: "d/a.jpg", uti: "public.jpeg", mediaType: .image, control: ExportControl())
        let primary = ImportLocator(sourceId: sourceId, relativePath: "d/a.jpg")
        _ = try await sut.exportResource(ResourceLocator(sourceId: sourceId, localId: primary.localId, type: .photo, originalFilename: "a.jpg"),
                                         to: base.appendingPathComponent("out"), control: ExportControl())
        #expect(try snapshot() == before)
    }

    @Test func aLocatorOfAnotherSourceIsRefused() async throws {
        try write("a.jpg")
        let other = ImportLocator(sourceId: .folder(), relativePath: "a.jpg")
        await #expect(throws: SourceError.fileMissing) {
            try await source().exportResource(ResourceLocator(sourceId: sourceId, localId: other.localId, type: .photo, originalFilename: "a.jpg"),
                                              to: base.appendingPathComponent("o"), control: ExportControl())
        }
    }
}

@Suite struct ReadOnlyBookmarkTests {
    @Test func aReadOnlyBookmarkResolvesAndListsTheFolder() async throws {
        let base = try TestFiles.temporaryDirectory("pv-ro").resolvingSymlinksInPath()
        let root = base.appendingPathComponent("pick", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("a.jpg"))
        let bookmark = try SecurityScopedBookmarkRoot.makeBookmark(for: root, readOnly: true)
        let access = SecurityScopedBookmarkRoot(bookmark: bookmark, readOnly: true, onRefresh: { _ in })
        let source = LocalFolderSource(id: .folder(), root: access, metadata: StubReader())
        try await source.probe()
        #expect(try await source.listFiles().map(\.relativePath) == ["a.jpg"])
    }

    private struct StubReader: FileMetadataReading {
        func fileMetadata(of file: URL, uti: String, mediaType: MediaType) -> FileMetadata { .empty }
    }
}
