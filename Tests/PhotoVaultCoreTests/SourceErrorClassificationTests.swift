import Testing
@testable import PhotoVaultCore

@Suite struct SourceErrorClassificationTests {
    @Test func classes() {
        #expect(ErrorClassifier.classify(SourceError.unavailable) == .destinationLevel(nil))
        #expect(ErrorClassifier.classify(SourceError.fileMissing) == .permanent(.resourceMissing))
        #expect(ErrorClassifier.classify(SourceError.fileChanged) == .permanent(.resourceMissing))
        #expect(ErrorClassifier.classify(SourceError.cancelled) == .transient)
        #expect(ErrorClassifier.classify(SourceError.readFailed(code: 5)) == .itemLevel)
    }
}
