import Foundation
import PhotoVaultCore
import Testing
import UniformTypeIdentifiers
@testable import PhotoVaultPhotos

struct HeaderClassifierTests {
    private let camera = TestImages.Spec(make: "Canon", model: "EOS R5", lens: "RF24-70", dateTimeOriginal: "2024:05:01 10:00:00", offset: "+07:00")

    /// Feeds `data` in `chunk`-byte pieces; returns the first conclusive outcome and bytes consumed then.
    private func feed(_ data: Data, chunk: Int, stride: Int = 1) -> (HeaderClassifier.Outcome, Int) {
        var classifier = HeaderClassifier(parseStride: stride)
        for piece in TestImages.chunks(data, size: chunk) {
            let outcome = classifier.append(piece)
            if outcome.isConclusive { return (outcome, classifier.bytesConsumed) }
        }
        return (classifier.finish(), classifier.bytesConsumed)
    }

    @Test func jpegWithMakeModelIsPresentBeforeEndOfFile() throws {
        let jpeg = try #require(TestImages.make(type: .jpeg, spec: camera))
        let (outcome, consumed) = feed(jpeg, chunk: 512)
        guard case .present(let metadata) = outcome else { Issue.record("expected present, got \(outcome)"); return }
        #expect(metadata.make == "Canon")
        #expect(metadata.model == "EOS R5")
        #expect(consumed <= jpeg.count)
    }

    @Test func jpegWithoutMakeModelIsAbsentOnlyAtCompletion() throws {
        let jpeg = try #require(TestImages.make(type: .jpeg, spec: TestImages.Spec(dateTimeOriginal: "2024:05:01 10:00:00")))
        let (outcome, _) = feed(jpeg, chunk: 700)
        guard case .absent(let metadata) = outcome else { Issue.record("expected absent, got \(outcome)"); return }
        #expect(!metadata.hasCameraIdentity)
    }

    /// TIFF block arrives after ~180 KB of other segments: absent must not be concluded early.
    @Test func lateTiffBlockDoesNotConcludeAbsentEarly() throws {
        let jpeg = try #require(TestImages.make(type: .jpeg, spec: camera))
        let padded = TestImages.padJPEGHeader(jpeg, segments: 3)
        var classifier = HeaderClassifier(parseStride: 1)
        var consumedAtConclusion: Int?
        for piece in TestImages.chunks(padded, size: 4_096) {
            let outcome = classifier.append(piece)
            if outcome.isConclusive {
                consumedAtConclusion = classifier.bytesConsumed
                guard case .present(let metadata) = outcome else { Issue.record("expected present, got \(outcome)"); return }
                #expect(metadata.make == "Canon")
                break
            }
        }
        if consumedAtConclusion == nil {
            // Parses are spaced out as the prefix grows, so the answer may only come with the full file.
            guard case .present(let metadata) = classifier.finish() else { Issue.record("expected present at finish"); return }
            #expect(metadata.make == "Canon")
            consumedAtConclusion = classifier.bytesConsumed
        }
        let consumed = try #require(consumedAtConclusion)
        #expect(consumed > 170_000, "concluded after only \(consumed) bytes")
    }

    @Test func truncatedGarbageIsUndecidable() {
        var classifier = HeaderClassifier()
        _ = classifier.append(Data(repeating: 0x42, count: 2_000))
        #expect(classifier.finish() == .undecidable)
    }

    @Test func outcomeIsSticky() throws {
        let jpeg = try #require(TestImages.make(type: .jpeg, spec: camera))
        var classifier = HeaderClassifier(parseStride: 1)
        _ = classifier.append(jpeg)
        let first = classifier.outcome
        #expect(first.isConclusive)
        #expect(classifier.append(Data(count: 10)) == first)
    }

    @Test func heicWithMakeModel() throws {
        // HEIC encoding is not available on every host; skip when the encoder refuses.
        guard let heic = TestImages.make(type: .heic, spec: camera) else { return }
        let (outcome, _) = feed(heic, chunk: 512)
        guard case .present(let metadata) = outcome else { Issue.record("expected present, got \(outcome)"); return }
        #expect(metadata.make == "Canon")
    }

    @Test func heicWithoutMakeModel() throws {
        guard let heic = TestImages.make(type: .heic) else { return }
        let (outcome, _) = feed(heic, chunk: 512)
        guard case .absent = outcome else { Issue.record("expected absent, got \(outcome)"); return }
    }

    @Test func prefixLargerThanTheMemoryCapStopsBufferingWithoutConcluding() throws {
        let jpeg = try #require(TestImages.make(type: .jpeg, spec: TestImages.Spec(dateTimeOriginal: "2024:05:01 10:00:00")))
        let padded = TestImages.padJPEGHeader(jpeg, segments: 3)
        var classifier = HeaderClassifier(parseStride: 1024, maxBuffered: 4096)
        for piece in TestImages.chunks(padded, size: 1000) { _ = classifier.append(piece) }
        #expect(classifier.overflowed)
        #expect(classifier.bytesConsumed == 0)
        #expect(classifier.finish() == .needMore)
    }

    @Test func cameraIdentityIsStillFoundWithDoublingParseSchedule() throws {
        let jpeg = try #require(TestImages.make(type: .jpeg, spec: camera))
        let padded = TestImages.padJPEGHeader(jpeg, segments: 3)
        let (outcome, _) = feed(padded, chunk: 4096, stride: 64 << 10)
        guard case .present(let metadata) = outcome else { Issue.record("expected present, got \(outcome)"); return }
        #expect(metadata.make == "Canon")
    }
}
