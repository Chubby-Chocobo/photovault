import Foundation
import PhotoVaultCore
import Testing
import UniformTypeIdentifiers
@testable import PhotoVaultPhotos

/// Opening bytes of real RAW files kept in git (public domain, see Fixtures/RawHeaders/README.md).
struct RawHeaderFixtureTests {
    struct Fixture: Decodable, Sendable, CustomTestStringConvertible {
        var file: String
        var make: String?
        var model: String
        /// ImageIO names the model only; the make comes from the file itself.
        var imageIOLacksMake: Bool?
        /// False when the file's own fallback cannot name the camera.
        var fallback: Bool?
        var testDescription: String { file }
    }

    static let directory = "Fixtures/RawHeaders"

    static func loadFixtures() throws -> [Fixture] {
        let url = try #require(Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: directory))
        return try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
    }

    static let fixtures: [Fixture] = (try? loadFixtures()) ?? []

    private func load(_ fixture: Fixture) throws -> (data: Data, uti: String) {
        let url = try #require(Bundle.module.url(forResource: fixture.file, withExtension: nil, subdirectory: Self.directory))
        let uti = try #require(UTType(filenameExtension: url.pathExtension)?.identifier)
        return (try Data(contentsOf: url), uti)
    }

    /// Every prefix in the folder is in the manifest and every entry has its file.
    @Test func theManifestMatchesTheFolder() throws {
        let listed = Set(try Self.loadFixtures().map(\.file))
        let folder = try #require(Bundle.module.url(forResource: Self.directory, withExtension: nil))
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)).subtracting(["manifest.json", "README.md"])
        #expect(listed == files)
        #expect(!listed.isEmpty)
    }

    /// RAW is decided by the UTI at scan time and makes the photo a camera photo, whatever its metadata.
    @Test(arguments: fixtures) func aRawIsAlwaysACameraPhoto(_ fixture: Fixture) throws {
        let (_, uti) = try load(fixture)
        let isRaw = UTTypeResolver().isRaw(uti)
        #expect(isRaw, "\(uti) must count as RAW")
        let result = CategoryClassifier.classify(mediaType: .image, subtypes: [], hasRaw: isRaw, albumTitles: [],
                                                 settings: GlobalSettings(), headerMetadata: nil)
        #expect(result.category == .camera && !result.provisional)
    }

    /// With the UTI, ImageIO finds the camera in the first PhotoKit chunk (the prefix is smaller than one).
    @Test(arguments: fixtures) func imageIOFindsTheCameraInTheFirstChunk(_ fixture: Fixture) throws {
        let (data, uti) = try load(fixture)
        let classifier = HeaderClassifierBox(typeHint: uti)
        #expect(classifier.append(data), "no answer from \(data.count) bytes")
        let result = PhotoKitSource.headerResult(classifier, completeFile: nil, uti: uti)
        #expect(result.isConclusive)
        #expect(result.metadata?.make == (fixture.imageIOLacksMake == true ? nil : fixture.make))
        #expect(result.metadata?.model == fixture.model)
    }

    /// Without ImageIO (a camera newer than the installed macOS), the file itself still names the camera.
    @Test(arguments: fixtures.filter { $0.fallback != false }) func theFileItselfNamesTheCamera(_ fixture: Fixture) throws {
        let (data, _) = try load(fixture)
        let found = RawCameraFallback.metadata(in: data)
        #expect(found?.make == fixture.make)
        #expect(found?.model == fixture.model)
    }
}
