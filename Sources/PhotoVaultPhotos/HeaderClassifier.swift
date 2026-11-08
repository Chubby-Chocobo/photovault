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

    private let source: CGImageSource
    private let parseStride: Int
    private var buffer = Data()
    private var consumedAtLastParse = 0
    private(set) var outcome: Outcome = .needMore

    /// - Parameter parseStride: bytes of new data between ImageIO updates. `CGImageSourceUpdateData`
    ///   takes the whole prefix each time, so parsing every chunk would be quadratic.
    init(parseStride: Int = 64 << 10) {
        self.parseStride = max(1, parseStride)
        self.source = CGImageSourceCreateIncremental(nil)
    }

    var bytesConsumed: Int { buffer.count }

    /// Feeds the next chunk, in order. Returns the (sticky) outcome.
    mutating func append(_ chunk: Data) -> Outcome {
        guard outcome == .needMore else { return outcome }
        buffer.append(chunk)
        if buffer.count - consumedAtLastParse >= parseStride {
            evaluate(isFinal: false)
        }
        return outcome
    }

    /// Declares that the whole file has been delivered.
    mutating func finish() -> Outcome {
        guard outcome == .needMore else { return outcome }
        evaluate(isFinal: true)
        return outcome
    }

    private mutating func evaluate(isFinal: Bool) {
        consumedAtLastParse = buffer.count
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
