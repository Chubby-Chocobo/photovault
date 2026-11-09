import CryptoKit
import Foundation
import PhotoVaultCore
import Testing
import UniformTypeIdentifiers
@testable import PhotoVaultPhotos

private let mediaCorpusDirectory: URL? = ProcessInfo.processInfo.environment["PHOTOVAULT_MEDIA_CORPUS"]
    .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

/// Complete RAW files kept outside git (see Fixtures/MediaCorpus/README.md). Runs when
/// `PHOTOVAULT_MEDIA_CORPUS` names the directory `scripts/fetch-media-corpus.py` filled; CI always sets it.
@Suite(.enabled(if: mediaCorpusDirectory != nil, "set PHOTOVAULT_MEDIA_CORPUS to run the media corpus"))
struct MediaCorpusTests {
    struct Expectation: Decodable, Sendable {
        var isRaw: Bool
        var make: String?
        var model: String?
        /// False when the file's own fallback cannot name the camera.
        var fallback: Bool?
        /// The format carries no capture date ImageIO reads.
        var noCaptureDate: Bool?
    }

    struct Entry: Decodable, Sendable, CustomTestStringConvertible {
        var id: String
        var file: String
        var sha256: String
        var expect: Expectation
        var testDescription: String { id }
    }

    static func loadEntries() throws -> [Entry] {
        let url = try #require(Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "Fixtures/MediaCorpus"))
        return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
    }

    static let entries: [Entry] = (try? loadEntries()) ?? []

    /// The file, checked against the manifest, copied without extension as staging keeps it.
    private func stage(_ entry: Entry) throws -> (staged: URL, uti: String) {
        let url = try #require(mediaCorpusDirectory).appendingPathComponent(entry.file)
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try #require(digest == entry.sha256, "\(entry.file) does not match the manifest; run scripts/fetch-media-corpus.py")
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: staged)
        return (staged, UTType(filenameExtension: url.pathExtension)?.identifier ?? "")
    }

    /// Every entry decodes and has a unique file; the corpus directory holds each of them.
    @Test func theManifestDecodesAndEveryFileIsThere() throws {
        let entries = try Self.loadEntries()
        #expect(!entries.isEmpty)
        #expect(Set(entries.map(\.file)).count == entries.count)
        let directory = try #require(mediaCorpusDirectory)
        for entry in entries {
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.file).path), "\(entry.file) is missing")
        }
    }

    /// RAW is decided by the UTI at scan time and makes the photo a camera photo, whatever its metadata.
    @Test(arguments: entries) func aRawIsAlwaysACameraPhoto(_ entry: Entry) throws {
        let (staged, uti) = try stage(entry)
        defer { try? FileManager.default.removeItem(at: staged) }
        let isRaw = UTTypeResolver().isRaw(uti)
        #expect(isRaw == entry.expect.isRaw)
        guard isRaw else { return }
        let result = CategoryClassifier.classify(mediaType: .image, subtypes: [], hasRaw: true, albumTitles: [],
                                                 settings: GlobalSettings(), headerMetadata: nil)
        #expect(result.category == .camera && !result.provisional)
    }

    /// What the export step stores for the by-device view and the sidecars.
    @Test(arguments: entries) func theStagedFileNamesTheCamera(_ entry: Entry) throws {
        let (staged, uti) = try stage(entry)
        defer { try? FileManager.default.removeItem(at: staged) }
        let metadata = ImageIOMetadataReader().metadata(of: staged, uti: uti, mediaType: .image)
        #expect(metadata.make == entry.expect.make)
        #expect(metadata.model == entry.expect.model)
        // The capture date comes from ImageIO (or an embedded preview), never from the TIFF fallback:
        // its absence shows the reader lost the type.
        if entry.expect.model != nil, entry.expect.noCaptureDate != true {
            #expect(metadata.dateTimeOriginal != nil, "no capture date")
        }
    }

    /// Without ImageIO (a camera newer than the installed macOS), the file itself still names the camera.
    @Test(arguments: entries.filter { $0.expect.fallback != false }) func theFileItselfNamesTheCamera(_ entry: Entry) throws {
        let (staged, _) = try stage(entry)
        defer { try? FileManager.default.removeItem(at: staged) }
        let found = RawCameraFallback.metadata(of: staged)
        #expect(found?.make == entry.expect.make)
        #expect(found?.model == entry.expect.model)
    }
}
