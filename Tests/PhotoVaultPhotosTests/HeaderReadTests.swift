import Foundation
import PhotoVaultCore
import Testing
import UniformTypeIdentifiers
@testable import PhotoVaultPhotos

/// The header read that classifies photos without RAW (FR-20 rule 3), driven the way
/// `readClassificationHeader` drives it: 1 MiB chunks until the classifier stops the read, then
/// `PhotoKitSource.headerResult`.
struct HeaderReadTests {
    private static let chunk = 1 << 20

    /// Feeds `data` until the classifier asks to stop; returns the bytes delivered.
    private func stream(_ data: Data, into classifier: HeaderClassifierBox) -> Int {
        var delivered = 0
        for piece in TestImages.chunks(data, size: Self.chunk) {
            delivered += piece.count
            if classifier.append(piece) { break }
        }
        return delivered
    }

    private func completeFile(_ data: Data) throws -> ExportedFile {
        let url = TestImages.tempURL(UUID().uuidString)
        try data.write(to: url)
        return ExportedFile(url: url, size: Int64(data.count), md5: "", sha256: "")
    }

    private let camera = TestImages.Spec(make: "Apple", model: "iPhone 17 Pro", lens: "Main", dateTimeOriginal: "2026:11:01 08:00:00")

    /// An iCloud-only JPEG costs one chunk to classify, however large the file.
    @Test func aLargeCameraJpegIsClassifiedFromTheFirstChunk() throws {
        let data = try #require(TestImages.make(type: .jpeg, spec: camera, size: 1500, noise: true))
        try #require(data.count > Self.chunk, "the sample must span several chunks (\(data.count) bytes)")
        let classifier = HeaderClassifierBox(typeHint: UTType.jpeg.identifier)
        #expect(stream(data, into: classifier) <= Self.chunk)
        let result = PhotoKitSource.headerResult(classifier, completeFile: nil, uti: UTType.jpeg.identifier)
        #expect(result.isConclusive && result.completeFile == nil)
        #expect(result.metadata?.make == "Apple" && result.metadata?.model == "iPhone 17 Pro")
    }

    /// ImageIO names a HEIC's camera only once the whole file is there (as measured on iPhone photos);
    /// the download is then kept as the staged copy instead of being fetched again.
    @Test func aCameraHeicIsReadWholeAndKept() throws {
        guard let data = TestImages.make(type: .heic, spec: camera, size: 1500, noise: true) else { return }
        try #require(data.count > Self.chunk, "the sample must span several chunks (\(data.count) bytes)")
        let classifier = HeaderClassifierBox(typeHint: UTType.heic.identifier)
        let delivered = stream(data, into: classifier)
        let file = try completeFile(data)
        defer { try? FileManager.default.removeItem(at: file.url) }
        let result = PhotoKitSource.headerResult(classifier, completeFile: classifier.stoppedEarly ? nil : file, uti: UTType.heic.identifier)
        #expect(result.isConclusive)
        #expect(result.metadata?.make == "Apple" && result.metadata?.model == "iPhone 17 Pro")
        if delivered == data.count {
            #expect(result.completeFile?.url == file.url, "a whole download must be kept")
        }
    }

    /// JPEG metadata always precedes the image data, so "no camera" is known once ImageIO reports
    /// the properties complete, also within the first chunk.
    @Test func aPhotoWithoutCameraIsClassifiedFromTheFirstChunk() throws {
        let data = try #require(TestImages.make(type: .jpeg, spec: TestImages.Spec(dateTimeOriginal: "2026:11:01 08:00:00"), size: 1500, noise: true))
        try #require(data.count > Self.chunk)
        let classifier = HeaderClassifierBox(typeHint: UTType.jpeg.identifier)
        #expect(stream(data, into: classifier) <= Self.chunk)
        let result = PhotoKitSource.headerResult(classifier, completeFile: nil, uti: UTType.jpeg.identifier)
        #expect(result.isConclusive)
        #expect(result.metadata?.hasCameraIdentity == false)
    }

    /// When the read ends without an early answer, the whole resource is kept as the staged copy.
    @Test func aFileThatArrivesWholeIsKept() throws {
        let data = try #require(TestImages.make(type: .png, spec: TestImages.Spec()))
        let classifier = HeaderClassifierBox(typeHint: UTType.png.identifier)
        _ = stream(data, into: classifier)
        try #require(!classifier.stoppedEarly, "PNG properties are only final at the end of the file")
        let file = try completeFile(data)
        defer { try? FileManager.default.removeItem(at: file.url) }
        let result = PhotoKitSource.headerResult(classifier, completeFile: file, uti: UTType.png.identifier)
        #expect(result.isConclusive)
        #expect(result.completeFile?.url == file.url)
    }

    /// A header that never decides is not held in memory past 32 MiB, however large the resource.
    @Test func anUndecidableHeaderStopsBufferingAt32MiB() {
        let classifier = HeaderClassifierBox(typeHint: UTType.jpeg.identifier)
        let zeros = Data(count: Self.chunk)
        var delivered = 0
        while delivered < 40 << 20, !classifier.overflowed {
            _ = classifier.append(zeros)
            delivered += zeros.count
        }
        #expect(classifier.overflowed)
        #expect(delivered <= 33 << 20, "buffered \(delivered >> 20) MiB before giving up")
    }

    /// Past the in-memory limit the complete file is read, with the resource's type: the staged copy
    /// has no extension, and a RAW needs its UTI (here the file's own directory names the camera).
    @Test func anOverflowingHeaderIsReadFromTheCompleteFileWithItsType() throws {
        let url = try #require(Bundle.module.url(forResource: "sony-arw.arw", withExtension: nil, subdirectory: "Fixtures/RawHeaders"))
        // Padded past the 64 KiB minimum buffer so the classifier gives up holding it in memory.
        let data = try Data(contentsOf: url) + Data(repeating: 0, count: 128 << 10)
        let uti = "com.sony.arw-raw-image"
        let classifier = HeaderClassifierBox(typeHint: uti, maxBuffered: 8 << 10)
        _ = stream(data, into: classifier)
        #expect(classifier.overflowed)
        let file = try completeFile(data)
        defer { try? FileManager.default.removeItem(at: file.url) }
        let result = PhotoKitSource.headerResult(classifier, completeFile: file, uti: uti)
        #expect(result.isConclusive)
        #expect(result.metadata?.make == "SONY" && result.metadata?.model == "ILCE-6400")
        #expect(result.completeFile != nil)
    }
}
