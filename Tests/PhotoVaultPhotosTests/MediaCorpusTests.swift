import CryptoKit
import Foundation
import PhotoVaultCore
import Testing
import UniformTypeIdentifiers
@testable import PhotoVaultPhotos

/// Complete RAW files kept outside git (see Fixtures/MediaCorpus/README.md). Runs when
/// `PHOTOVAULT_MEDIA_CORPUS` names the directory `scripts/fetch-media-corpus.py` filled; CI always sets it.
private let mediaCorpusDirectory: URL? = ProcessInfo.processInfo.environment["PHOTOVAULT_MEDIA_CORPUS"]
    .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

@Suite(.enabled(if: mediaCorpusDirectory != nil, "set PHOTOVAULT_MEDIA_CORPUS to run the media corpus"))
struct MediaCorpusTests {
    struct Expectation: Decodable, Sendable {
        var isRaw: Bool
        var make: String?
        var model: String?
        var maxHeaderBytes: Int?
        var fromCompleteFile: Bool?
        var unsupported: Bool?
    }

    struct Entry: Decodable, Sendable, CustomTestStringConvertible {
        var id: String
        var file: String
        var sha256: String
        var expect: Expectation
        var testDescription: String { id }
    }

    static let entries: [Entry] = {
        guard let url = Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "Fixtures/MediaCorpus"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }()

    private static let chunk = 1 << 20

    /// The file, checked against the manifest, and a copy without extension as staging keeps it.
    private func load(_ entry: Entry) throws -> (data: Data, staged: URL, uti: String) {
        let directory = try #require(mediaCorpusDirectory)
        let url = directory.appendingPathComponent(entry.file)
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try #require(digest == entry.sha256, "\(entry.file) does not match the manifest; run scripts/fetch-media-corpus.py")
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: staged)
        let uti = UTType(filenameExtension: url.pathExtension)?.identifier ?? ""
        return (data, staged, uti)
    }

    @Test func theManifestListsTheCorpus() {
        #expect(Self.entries.count >= 25)
    }

    @Test(arguments: entries) func theCameraIsReadFromTheHeader(_ entry: Entry) throws {
        let (data, staged, uti) = try load(entry)
        defer { try? FileManager.default.removeItem(at: staged) }
        #expect(UTTypeResolver().isRaw(uti) == entry.expect.isRaw)

        // As readClassificationHeader does: 1 MiB chunks until conclusive, the whole file is the
        // final answer, and a full buffer falls back to reading the complete file.
        var classifier = HeaderClassifier(typeHint: uti)
        var outcome = HeaderClassifier.Outcome.needMore
        var consumed = 0
        while consumed < data.count, !outcome.isConclusive, !classifier.overflowed {
            let end = min(consumed + Self.chunk, data.count)
            outcome = classifier.append(data.subdata(in: consumed..<end))
            consumed = end
        }
        if classifier.overflowed {
            #expect(entry.expect.fromCompleteFile == true || entry.expect.unsupported == true,
                    "the header no longer names the camera within the buffer")
            let metadata = ImageIOMetadataReader.imageMetadata(of: staged, uti: uti)
            #expect(metadata.make == entry.expect.make)
            #expect(metadata.model == entry.expect.model)
            return
        }
        if !outcome.isConclusive { outcome = classifier.finish() }
        if entry.expect.unsupported == true {
            if case .present = outcome { Issue.record("an unsupported format now names a camera: update the manifest") }
            return
        }
        guard case .present(let metadata) = outcome else {
            Issue.record("no camera from the header: \(outcome)")
            return
        }
        #expect(metadata.make == entry.expect.make)
        #expect(metadata.model == entry.expect.model)
        if let budget = entry.expect.maxHeaderBytes {
            #expect(consumed <= budget, "classification read \(consumed) bytes, budget \(budget)")
        }
    }

    @Test(arguments: entries) func theCameraIsReadFromTheStagedFile(_ entry: Entry) throws {
        let (_, staged, uti) = try load(entry)
        defer { try? FileManager.default.removeItem(at: staged) }
        let metadata = ImageIOMetadataReader().metadata(of: staged, uti: uti, mediaType: .image)
        #expect(metadata.make == entry.expect.make)
        #expect(metadata.model == entry.expect.model)
    }
}
