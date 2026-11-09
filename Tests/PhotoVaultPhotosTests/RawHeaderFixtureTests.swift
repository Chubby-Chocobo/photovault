import Foundation
import PhotoVaultCore
import Testing
import UniformTypeIdentifiers
@testable import PhotoVaultPhotos

/// Opening bytes of real RAW files (public domain, see Fixtures/RawHeaders/README.md): the camera must
/// be found from these bytes alone, given the resource's UTI.
struct RawHeaderFixtureTests {
    struct Fixture: Decodable, Sendable, CustomTestStringConvertible {
        var file: String
        var make: String?
        var model: String
        var testDescription: String { file }
    }

    static let fixtures: [Fixture] = {
        guard let url = Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "Fixtures/RawHeaders"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Fixture].self, from: data)) ?? []
    }()

    @Test func theManifestListsTheFixtures() {
        #expect(Self.fixtures.count >= 20)
    }

    @Test(arguments: fixtures) func theFirstChunkNamesTheCamera(_ fixture: Fixture) throws {
        let url = try #require(Bundle.module.url(forResource: fixture.file, withExtension: nil, subdirectory: "Fixtures/RawHeaders"))
        let uti = try #require(UTType(filenameExtension: url.pathExtension)?.identifier)
        #expect(UTTypeResolver().isRaw(uti), "\(uti) must count as RAW")
        // The prefix is smaller than one PhotoKit chunk, so it arrives as one append.
        var classifier = HeaderClassifier(typeHint: uti)
        let outcome = classifier.append(try Data(contentsOf: url))
        guard case .present(let metadata) = outcome else {
            Issue.record("no camera found in \(fixture.file): \(outcome)")
            return
        }
        #expect(metadata.make == fixture.make)
        #expect(metadata.model == fixture.model)
    }
}
