import Foundation
import ImageIO
import PhotoVaultCore

/// Incremental TIFF Make/Model detection over a growing prefix of an image file (FR-20).
///
/// "Absent" is concluded only when ImageIO reports the image complete or the caller says the whole
/// file arrived; until then the answer is `.needMore`, because Make/Model may sit in a block that has
/// not arrived yet. Independent of PhotoKit so it can be tested with generated files.
struct HeaderClassifier {
    enum Outcome: Equatable {
        case needMore
        /// TIFF Make or Model found.
        case present(CaptureMetadata)
        /// Properties are fully known and carry neither Make nor Model.
        case absent(CaptureMetadata)
        /// The whole input arrived but ImageIO could not read properties (unsupported format).
        case undecidable

        var isConclusive: Bool { self != .needMore }
    }

    static let maxParseIncrement = 1 << 20
    /// Largest prefix held in memory; past it the complete file is read instead.
    static let defaultMaxBuffered = 32 << 20

    private let source: CGImageSource
    private let parseStride: Int
    private let maxBuffered: Int
    private var buffer = Data()
    private var nextParseAt: Int
    private(set) var outcome: Outcome = .needMore
    /// The prefix grew past `maxBuffered` without an answer: buffering stopped, and the caller
    /// classifies from the complete file on disk instead.
    private(set) var overflowed = false

    /// - Parameters:
    ///   - parseStride: bytes before the first ImageIO update. `CGImageSourceUpdateData` takes the
    ///     whole prefix each time, so later updates wait until the prefix doubles, at most
    ///     `maxParseIncrement` more bytes, keeping both total work and detection delay bounded.
    ///   - maxBuffered: largest prefix kept in memory.
    ///   - typeHint: the resource's UTI. Without it ImageIO takes a Sony ARW for a plain TIFF and
    ///     finds no properties at all, so every RAW would look like a photo without a camera.
    init(parseStride: Int = 64 << 10, maxBuffered: Int = defaultMaxBuffered, typeHint: String? = nil) {
        self.parseStride = max(1, parseStride)
        self.maxBuffered = max(self.parseStride, maxBuffered)
        self.nextParseAt = self.parseStride
        self.source = CGImageSourceCreateIncremental(ImageIOMetadataReader.sourceOptions(uti: typeHint))
    }

    /// The type ImageIO decided on for the data so far.
    var sourceType: String? { CGImageSourceGetType(source) as String? }

    var bytesConsumed: Int { buffer.count }

    /// Feeds the next chunk, in order. Returns the (sticky) outcome.
    mutating func append(_ chunk: Data) -> Outcome {
        guard outcome == .needMore, !overflowed else { return outcome }
        if buffer.count + chunk.count > maxBuffered {
            overflowed = true
            buffer = Data()
            return outcome
        }
        buffer.append(chunk)
        if buffer.count >= nextParseAt {
            evaluate(isFinal: false)
            nextParseAt = buffer.count + min(max(parseStride, buffer.count), Self.maxParseIncrement)
        }
        return outcome
    }

    /// Declares that the whole file has been delivered.
    mutating func finish() -> Outcome {
        guard outcome == .needMore, !overflowed else { return outcome }
        evaluate(isFinal: true)
        return outcome
    }

    private mutating func evaluate(isFinal: Bool) {
        CGImageSourceUpdateData(source, buffer as CFData, isFinal)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        if let props {
            let metadata = ImageIOMetadataReader.metadata(from: props)
            if metadata.hasCameraIdentity {
                outcome = .present(metadata)
                return
            }
            if isFinal || CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete {
                outcome = .absent(metadata)
                return
            }
        } else if isFinal {
            outcome = .undecidable
        }
    }
}
