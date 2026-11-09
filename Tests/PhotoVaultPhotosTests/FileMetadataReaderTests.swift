import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import PhotoVaultCore
import Testing
import UniformTypeIdentifiers
@testable import PhotoVaultPhotos

@Suite struct FileMetadataReaderTests {
    let reader = ImageIOMetadataReader()

    private func image(
        type: UTType = .jpeg, exif: [CFString: Any] = [:], tiff: [CFString: Any] = [:], gps: [CFString: Any]? = nil,
        orientation: Int? = nil, width: Int = 64, height: Int = 32
    ) throws -> URL {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        var props: [CFString: Any] = [:]
        if !exif.isEmpty { props[kCGImagePropertyExifDictionary] = exif }
        if !tiff.isEmpty { props[kCGImagePropertyTIFFDictionary] = tiff }
        if let gps { props[kCGImagePropertyGPSDictionary] = gps }
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), props as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        let url = TestImages.tempURL("meta-\(UUID().uuidString).\(type.preferredFilenameExtension ?? "bin")")
        try (data as Data).write(to: url)
        return url
    }

    @Test func jpegWithExifGpsAndCamera() throws {
        let url = try image(
            exif: [kCGImagePropertyExifDateTimeOriginal: "2025:03:01 07:55:30", kCGImagePropertyExifOffsetTimeOriginal: "+07:00",
                   kCGImagePropertyExifLensModel: "FE 24-70"],
            tiff: [kCGImagePropertyTIFFMake: "SONY", kCGImagePropertyTIFFModel: "ILCE-7M4"],
            gps: [kCGImagePropertyGPSLatitude: 11.9404, kCGImagePropertyGPSLatitudeRef: "S",
                  kCGImagePropertyGPSLongitude: 108.4583, kCGImagePropertyGPSLongitudeRef: "W"])
        let meta = reader.fileMetadata(of: url, uti: "public.jpeg", mediaType: .image)
        #expect(meta.capture.make == "SONY" && meta.capture.model == "ILCE-7M4" && meta.capture.lensModel == "FE 24-70")
        #expect(meta.capture.dateTimeOriginal == "2025:03:01 07:55:30" && meta.capture.offsetTime == "+07:00")
        #expect(meta.pixelWidth == 64 && meta.pixelHeight == 32)
        let location = try #require(meta.location)
        #expect(abs(location.latitude + 11.9404) < 1e-6 && abs(location.longitude + 108.4583) < 1e-6)
        #expect(!meta.isScreenshot && meta.contentIdentifier == nil)
    }

    @Test func screenshotCommentMarksAScreenshot() throws {
        for type in [UTType.png, .jpeg] {
            let url = try image(type: type, exif: [kCGImagePropertyExifUserComment: " Screenshot "])
            let meta = reader.fileMetadata(of: url, uti: type.identifier, mediaType: .image)
            #expect(meta.isScreenshot, "\(type.identifier)")
        }
        let other = try image(exif: [kCGImagePropertyExifUserComment: "A holiday"])
        #expect(!reader.fileMetadata(of: other, uti: "public.jpeg", mediaType: .image).isScreenshot)
    }

    @Test func orientedFileReportsStoredDimensions() throws {
        let url = try image(orientation: 6, width: 80, height: 40)
        let meta = reader.fileMetadata(of: url, uti: "public.jpeg", mediaType: .image)
        #expect(meta.pixelWidth == 80 && meta.pixelHeight == 40)
    }

    @Test func missingOrBrokenFilesGiveEmptyMetadata() {
        let missing = TestImages.tempURL("nope.jpg")
        #expect(reader.fileMetadata(of: missing, uti: "public.jpeg", mediaType: .image) == .empty)
        #expect(reader.fileMetadata(of: missing, uti: "com.apple.quicktime-movie", mediaType: .video) == .empty)
    }

    @Test func iso6709() {
        #expect(ImageIOMetadataReader.parseISO6709("+11.9404+108.4583+000.000/") == GeoPoint(latitude: 11.9404, longitude: 108.4583))
        #expect(ImageIOMetadataReader.parseISO6709("-33.8688+151.2093/") == GeoPoint(latitude: -33.8688, longitude: 151.2093))
        #expect(ImageIOMetadataReader.parseISO6709("+0.0000+0.0000/") == nil)
        #expect(ImageIOMetadataReader.parseISO6709("+95.0+10.0/") == nil)
        #expect(ImageIOMetadataReader.parseISO6709("nonsense") == nil)
    }

    // MARK: Video

    private func movie(contentId: String?, created: String?, location: String?) async throws -> URL {
        let url = TestImages.tempURL("clip-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48,
        ])
        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMutableMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = id
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            item.value = value as NSString
            return item
        }
        var items: [AVMetadataItem] = []
        if let contentId { items.append(item(.quickTimeMetadataContentIdentifier, contentId)) }
        if let created { items.append(item(.quickTimeMetadataCreationDate, created)) }
        if let location { items.append(item(.quickTimeMetadataLocationISO6709, location)) }
        writer.metadata = items
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer)
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            adaptor.append(try #require(buffer), withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed, "\(String(describing: writer.error))")
        return url
    }

    @Test func movieDateLocationDurationAndContentIdentifier() async throws {
        let url = try await movie(contentId: "E3A1-LIVE-1", created: "2024-05-01T10:00:00+0700", location: "+10.7769+106.7009+000.000/")
        let meta = reader.fileMetadata(of: url, uti: "com.apple.quicktime-movie", mediaType: .video)
        #expect(meta.contentIdentifier == "E3A1-LIVE-1")
        #expect(meta.captureDate == ISO8601DateFormatter().date(from: "2024-05-01T03:00:00Z"))
        #expect(meta.location == GeoPoint(latitude: 10.7769, longitude: 106.7009))
        #expect(abs(meta.duration - 1.0) < 0.2)
        #expect(meta.pixelWidth == 64 && meta.pixelHeight == 48)
    }

    @Test func movieWithoutMetadataHasOnlySize() async throws {
        let url = try await movie(contentId: nil, created: nil, location: nil)
        let meta = reader.fileMetadata(of: url, uti: "com.apple.quicktime-movie", mediaType: .video)
        #expect(meta.contentIdentifier == nil && meta.location == nil && meta.captureDate == nil && meta.pixelWidth == 64)
    }
}
