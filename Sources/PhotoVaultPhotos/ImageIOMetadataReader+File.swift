import AVFoundation
import Foundation
import ImageIO
import PhotoVaultCore

/// Everything an imported file says about itself: capture fields, size, place and, for Live Photos,
/// the content identifier that ties the image to its video.
extension ImageIOMetadataReader: FileMetadataReading {
    public func fileMetadata(of file: URL, uti: String, mediaType: MediaType) -> FileMetadata {
        mediaType == .video ? Self.videoFileMetadata(of: file) : Self.imageFileMetadata(of: file, uti: uti)
    }

    // MARK: Images

    static func imageFileMetadata(of file: URL, uti: String) -> FileMetadata {
        var result = FileMetadata(capture: imageMetadata(of: file, uti: uti))
        guard let source = imageSource(of: file, uti: uti),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return result }
        result.pixelWidth = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        result.pixelHeight = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        result.location = location(from: props[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let comment = (exif[kCGImagePropertyExifUserComment] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        result.isScreenshot = comment?.caseInsensitiveCompare("Screenshot") == .orderedSame
        let apple = props[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
        result.contentIdentifier = apple?["17"] as? String
        return result
    }

    static func location(from gps: [CFString: Any]?) -> GeoPoint? {
        guard let gps, let latitude = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
              let longitude = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue else { return nil }
        let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S"
        let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W"
        return validPoint(latitude: south ? -abs(latitude) : abs(latitude), longitude: west ? -abs(longitude) : abs(longitude))
    }

    private static func validPoint(latitude: Double, longitude: Double) -> GeoPoint? {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude), !(latitude == 0 && longitude == 0) else { return nil }
        return GeoPoint(latitude: latitude, longitude: longitude)
    }

    // MARK: Videos

    /// `+11.9404+108.4583+000.000/` (ISO 6709, as QuickTime stores it).
    static func parseISO6709(_ text: String) -> GeoPoint? {
        let scalars = Array(text.trimmingCharacters(in: .whitespaces))
        var numbers: [Double] = []
        var index = 0
        while index < scalars.count, numbers.count < 2 {
            guard scalars[index] == "+" || scalars[index] == "-" else { return nil }
            var end = index + 1
            while end < scalars.count, scalars[end].isNumber || scalars[end] == "." { end += 1 }
            guard let value = Double(String(scalars[index..<end])) else { return nil }
            numbers.append(value)
            index = end
        }
        guard numbers.count == 2 else { return nil }
        return validPoint(latitude: numbers[0], longitude: numbers[1])
    }

    static func videoFileMetadata(of file: URL) -> FileMetadata {
        let box = FileMetadataBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            box.set(await loadVideoFileMetadata(of: file))
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + videoTimeout) == .success else { return .empty }
        return box.value
    }

    private static func loadVideoFileMetadata(of file: URL) async -> FileMetadata {
        let asset = AVURLAsset(url: file)
        var result = FileMetadata.empty
        guard let items = try? await asset.load(.metadata) else { return result }
        func item(_ id: AVMetadataIdentifier) -> AVMetadataItem? { AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first }
        func string(_ id: AVMetadataIdentifier) async -> String? {
            guard let found = item(id), let value = try? await found.load(.stringValue) else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            return trimmed.isEmpty ? nil : trimmed
        }
        result.capture = CaptureMetadata(make: await string(.quickTimeMetadataMake), model: await string(.quickTimeMetadataModel))
        result.contentIdentifier = await string(.quickTimeMetadataContentIdentifier)
        if let text = await string(.quickTimeMetadataLocationISO6709) { result.location = parseISO6709(text) }
        for id in [AVMetadataIdentifier.quickTimeMetadataCreationDate, .commonIdentifierCreationDate] {
            guard let found = item(id) else { continue }
            if let date = try? await found.load(.dateValue) { result.captureDate = date; break }
        }
        if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite { result.duration = seconds }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
            let oriented = size.applying(transform)
            result.pixelWidth = Int(abs(oriented.width).rounded())
            result.pixelHeight = Int(abs(oriented.height).rounded())
        }
        return result
    }

    private final class FileMetadataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = FileMetadata.empty
        func set(_ value: FileMetadata) { lock.lock(); stored = value; lock.unlock() }
        var value: FileMetadata { lock.lock(); defer { lock.unlock() }; return stored }
    }
}
