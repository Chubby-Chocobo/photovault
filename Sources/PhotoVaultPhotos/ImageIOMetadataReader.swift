import AVFoundation
import Foundation
import ImageIO
import PhotoVaultCore

/// Reads capture metadata with ImageIO (images) and AVFoundation (videos) (FR-34).
/// Every failure yields empty fields, never an error.
public struct ImageIOMetadataReader: MetadataReading {
    /// Upper bound for the blocking bridge to AVFoundation's async loaders.
    static let videoTimeout: DispatchTimeInterval = .seconds(30)

    public init() {}

    public func metadata(of file: URL, uti: String, mediaType: MediaType) -> CaptureMetadata {
        switch mediaType {
        case .video:
            return Self.videoMetadata(of: file)
        default:
            return Self.imageMetadata(of: file, uti: uti)
        }
    }

    /// Staged files have no extension, so the type comes from the resource's UTI; ImageIO's own
    /// guess reads a Sony ARW as a plain TIFF without any properties.
    static func sourceOptions(uti: String?) -> CFDictionary {
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let uti, !uti.isEmpty { options[kCGImageSourceTypeIdentifierHint] = uti }
        return options as CFDictionary
    }

    static func imageSource(of file: URL, uti: String?) -> CGImageSource? {
        CGImageSourceCreateWithURL(file as CFURL, sourceOptions(uti: uti))
    }

    static func imageMetadata(of file: URL, uti: String?) -> CaptureMetadata {
        var read = CaptureMetadata.empty
        if let source = imageSource(of: file, uti: uti),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            read = metadata(from: props)
        }
        // A RAW from a camera newer than this macOS reads as nothing, and some formats lose the make
        // (Samsung SRW); the file itself still names the camera.
        guard read.make == nil || read.model == nil, let uti, UTTypeResolver().isRaw(uti),
              let found = RawCameraFallback.metadata(of: file) else { return read }
        return CaptureMetadata(
            make: read.make ?? found.make, model: read.model ?? found.model, lensModel: read.lensModel ?? found.lensModel,
            dateTimeOriginal: read.dateTimeOriginal ?? found.dateTimeOriginal, offsetTime: read.offsetTime ?? found.offsetTime)
    }

    /// Maps an ImageIO properties dictionary to `CaptureMetadata`.
    static func metadata(from props: [CFString: Any]) -> CaptureMetadata {
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        return CaptureMetadata(
            make: trimmed(tiff[kCGImagePropertyTIFFMake]),
            model: trimmed(tiff[kCGImagePropertyTIFFModel]),
            lensModel: trimmed(exif[kCGImagePropertyExifLensModel]) ?? trimmed(aux[kCGImagePropertyExifAuxLensModel]),
            dateTimeOriginal: trimmed(exif[kCGImagePropertyExifDateTimeOriginal]),
            offsetTime: trimmed(exif[kCGImagePropertyExifOffsetTimeOriginal]) ?? trimmed(exif[kCGImagePropertyExifOffsetTime])
        )
    }

    private static func trimmed(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let result = string.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return result.isEmpty ? nil : result
    }

    /// The protocol is synchronous while AVFoundation's loaders are async; wait on a task with a
    /// timeout so a stuck asset degrades to empty metadata instead of hanging the caller.
    static func videoMetadata(of file: URL) -> CaptureMetadata {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            box.set(await loadVideoMetadata(of: file))
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + videoTimeout) == .success else { return .empty }
        return box.value
    }

    private static func loadVideoMetadata(of file: URL) async -> CaptureMetadata {
        let asset = AVURLAsset(url: file)
        guard let items = try? await asset.load(.metadata) else { return .empty }
        func string(_ id: AVMetadataIdentifier) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first,
                  let value = try? await item.load(.stringValue) else { return nil }
            return trimmed(value)
        }
        return CaptureMetadata(make: await string(.quickTimeMetadataMake), model: await string(.quickTimeMetadataModel))
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = CaptureMetadata.empty
        func set(_ value: CaptureMetadata) { lock.lock(); stored = value; lock.unlock() }
        var value: CaptureMetadata { lock.lock(); defer { lock.unlock() }; return stored }
    }
}
