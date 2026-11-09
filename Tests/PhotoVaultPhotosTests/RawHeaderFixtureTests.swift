import Foundation
import PhotoVaultCore
import Testing
import UniformTypeIdentifiers
@testable import PhotoVaultPhotos

/// Real RAW headers (public-domain samples): ImageIO only finds their camera when told the type.
struct RawHeaderFixtureTests {
    struct Sample: Sendable, CustomTestStringConvertible {
        var file: String
        var make: String?
        var model: String
        var testDescription: String { file }
    }

    static let samples = [
        Sample(file: "sony-ilce-7rm5.ARW", make: "SONY", model: "ILCE-7RM5"),
        Sample(file: "nikon-z9-lossless.NEF", make: "NIKON CORPORATION", model: "NIKON Z 9"),
        Sample(file: "nikon-coolpix-p7800.NRW", make: "NIKON", model: "COOLPIX P7800"),
        Sample(file: "pentax-k-r.PEF", make: "PENTAX", model: "PENTAX K-r"),
        // ImageIO reports no make for Samsung; the model alone marks a camera.
        Sample(file: "samsung-nx1.SRW", make: nil, model: "NX1"),
    ]

    private func fixture(_ sample: Sample) throws -> (Data, String) {
        let url = try #require(Bundle.module.url(forResource: sample.file, withExtension: nil, subdirectory: "RawHeaders"))
        let uti = try #require(UTType(filenameExtension: url.pathExtension)?.identifier)
        #expect(UTTypeResolver().isRaw(uti))
        return (try Data(contentsOf: url), uti)
    }

    @Test(arguments: samples) func theHeaderNamesTheCamera(_ sample: Sample) throws {
        let (data, uti) = try fixture(sample)
        var classifier = HeaderClassifier(typeHint: uti)
        var outcome = HeaderClassifier.Outcome.needMore
        for chunk in TestImages.chunks(data, size: 16 << 10) where !outcome.isConclusive {
            outcome = classifier.append(chunk)
        }
        guard case .present(let metadata) = outcome else { Issue.record("expected the camera, got \(outcome)"); return }
        #expect(metadata.make == sample.make)
        #expect(metadata.model == sample.model)
    }
}
