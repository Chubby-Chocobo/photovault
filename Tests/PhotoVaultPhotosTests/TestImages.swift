import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generates images in-test with ImageIO.
enum TestImages {
    struct Spec {
        var make: String?
        var model: String?
        var lens: String?
        var dateTimeOriginal: String?
        var offset: String?
    }

    /// Returns nil when the encoder is unavailable (for example HEIC on a host without it).
    /// `noise` fills the pixels with fixed pseudo-random values, so the file stays large after
    /// compression, as a real photo does.
    static func make(type: UTType, spec: Spec = Spec(), size: Int = 256, noise: Bool = false) -> Data? {
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        if noise, let pixels = context.data {
            let words = context.bytesPerRow * size / 8
            let buffer = pixels.bindMemory(to: UInt64.self, capacity: words)
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            for index in 0..<words {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                buffer[index] = state
            }
        } else {
            for row in 0..<size {
                context.setFillColor(red: CGFloat(row % 255) / 255, green: CGFloat((row * 7) % 255) / 255, blue: 0.5, alpha: 1)
                context.fill(CGRect(x: 0, y: row, width: size, height: 1))
            }
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var tiff: [CFString: Any] = [:]
        if let make = spec.make { tiff[kCGImagePropertyTIFFMake] = make }
        if let model = spec.model { tiff[kCGImagePropertyTIFFModel] = model }
        var exif: [CFString: Any] = [:]
        if let lens = spec.lens { exif[kCGImagePropertyExifLensModel] = lens }
        if let date = spec.dateTimeOriginal { exif[kCGImagePropertyExifDateTimeOriginal] = date }
        if let offset = spec.offset { exif[kCGImagePropertyExifOffsetTimeOriginal] = offset }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if !tiff.isEmpty { props[kCGImagePropertyTIFFDictionary] = tiff }
        if !exif.isEmpty { props[kCGImagePropertyExifDictionary] = exif }
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Inserts `count` JPEG comment segments of ~60 KB right after SOI, pushing APP1 (Exif/TIFF) back.
    static func padJPEGHeader(_ jpeg: Data, segments count: Int) -> Data {
        var padded = Data(jpeg.prefix(2))
        let payload = [UInt8](repeating: 0x20, count: 60_000)
        let length = UInt16(payload.count + 2)
        for _ in 0..<count {
            padded.append(contentsOf: [0xFF, 0xFE, UInt8(length >> 8), UInt8(length & 0xFF)])
            padded.append(contentsOf: payload)
        }
        padded.append(jpeg.dropFirst(2))
        return padded
    }

    static func chunks(_ data: Data, size: Int) -> [Data] {
        stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0..<min($0 + size, data.count)) }
    }

    static func tempURL(_ name: String = UUID().uuidString) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pv-photos-\(name)")
    }
}
