import Foundation
import ImageIO
import PhotoVaultCore

/// Camera make and model of a RAW file that ImageIO cannot read, typically from a camera newer than
/// the installed macOS. Without them the photo would be missing from the by-device view and from the
/// sidecars, although its category (camera) does not depend on them.
///
/// Three places are tried, all near the start of the file:
/// - the first TIFF directories, which most RAW formats begin with (ARW, NEF, PEF, ORF, RW2, DNG, …);
/// - the TIFF block in the `CMT1` box of a Canon CR3;
/// - the Exif block of an embedded JPEG preview (RAF and others).
enum RawCameraFallback {
    /// Bytes read from the start of the file.
    static let scanLimit = 16 << 20
    private static let makeTag: UInt16 = 0x010F
    private static let modelTag: UInt16 = 0x0110
    private static let asciiType: UInt16 = 2
    private static let maxDirectories = 4

    static func metadata(of file: URL) -> CaptureMetadata? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: scanLimit) else { return nil }
        return metadata(in: data)
    }

    static func metadata(in data: Data) -> CaptureMetadata? {
        if let found = tiffDirectories(data), found.hasCameraIdentity { return found }
        if let found = canonCMT1(data), found.hasCameraIdentity { return found }
        if let found = embeddedExif(data), found.hasCameraIdentity { return found }
        return nil
    }

    /// CR3 is an ISO media file; its `CMT1` box holds a TIFF directory with Make and Model.
    static func canonCMT1(_ data: Data) -> CaptureMetadata? {
        guard let range = data.range(of: Data("CMT1".utf8)) else { return nil }
        return tiffDirectories(data, at: range.upperBound)
    }

    /// Make and Model from IFD0 and the directories chained after it. The two magic bytes after the
    /// byte order differ between formats (42 for TIFF, "RO" for ORF, 0x55 for RW2) and are not checked.
    /// Offsets inside the TIFF block count from `base`. Reads `data` in place, without copying it.
    static func tiffDirectories(_ data: Data, at base: Data.Index? = nil) -> CaptureMetadata? {
        let base = base ?? data.startIndex
        let end = min(data.endIndex, base + scanLimit)
        func byte(_ at: Int) -> UInt8? {
            let index = base + at
            return at >= 0 && index < end ? data[index] : nil
        }
        guard let first = byte(0), let second = byte(1), first == second, first == 0x49 || first == 0x4D else { return nil }
        let little = first == 0x49
        func u16(_ at: Int) -> UInt16? {
            guard let a = byte(at), let b = byte(at + 1) else { return nil }
            return little ? UInt16(a) | UInt16(b) << 8 : UInt16(a) << 8 | UInt16(b)
        }
        func u32(_ at: Int) -> UInt32? {
            guard let a = u16(at), let b = u16(at + 2) else { return nil }
            return little ? UInt32(a) | UInt32(b) << 16 : UInt32(a) << 16 | UInt32(b)
        }
        func ascii(count: Int, at: Int) -> String? {
            guard count > 0, at >= 0, base + at + count <= end else { return nil }
            let text = String(decoding: data[(base + at)..<(base + at + count)].prefix { $0 != 0 }, as: UTF8.self)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var make: String?, model: String?
        var offset = u32(4).map(Int.init) ?? 0
        var visited = Set<Int>()
        for _ in 0..<maxDirectories where offset > 0 && !visited.contains(offset) {
            visited.insert(offset)
            guard let count = u16(offset).map(Int.init), count < 1000 else { break }
            for index in 0..<count {
                let entry = offset + 2 + index * 12
                guard let tag = u16(entry), let type = u16(entry + 2), let length = u32(entry + 4).map(Int.init),
                      type == asciiType, tag == makeTag || tag == modelTag else { continue }
                let valueAt = length <= 4 ? entry + 8 : (u32(entry + 8).map(Int.init) ?? -1)
                let value = ascii(count: length, at: valueAt)
                if tag == makeTag { make = make ?? value } else { model = model ?? value }
            }
            if make != nil, model != nil { break }
            offset = u32(offset + 2 + count * 12).map(Int.init) ?? 0
        }
        guard make != nil || model != nil else { return nil }
        return CaptureMetadata(make: make, model: model)
    }

    /// The first embedded JPEG whose leading APPn segments include an Exif block, read by ImageIO.
    static func embeddedExif(_ data: Data) -> CaptureMetadata? {
        let soi = Data([0xFF, 0xD8, 0xFF])
        var from = data.startIndex
        while let range = data.range(of: soi, in: from..<data.endIndex) {
            if hasExifSegment(data, jpegAt: range.lowerBound) {
                // ImageIO needs its own buffer: this is the one copy, of the preview onwards.
                let jpeg = Data(data[range.lowerBound...])
                let options = [kCGImageSourceTypeIdentifierHint: "public.jpeg", kCGImageSourceShouldCache: false] as CFDictionary
                guard let source = CGImageSourceCreateWithData(jpeg as CFData, options),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
                return ImageIOMetadataReader.metadata(from: props)
            }
            from = range.lowerBound + 2
        }
        return nil
    }

    /// Walks the APPn and comment segments after SOI looking for an APP1 that starts with "Exif\0\0".
    private static func hasExifSegment(_ data: Data, jpegAt start: Data.Index) -> Bool {
        let signature: [UInt8] = Array("Exif".utf8) + [0, 0]
        var at = start + 2
        for _ in 0..<16 {
            guard at + 4 <= data.endIndex, data[at] == 0xFF else { return false }
            let marker = data[at + 1]
            guard (0xE0...0xEF).contains(marker) || marker == 0xFE else { return false }
            let length = Int(data[at + 2]) << 8 | Int(data[at + 3])
            guard length >= 2 else { return false }
            if marker == 0xE1, at + 4 + signature.count <= data.endIndex, data[(at + 4)..<(at + 4 + signature.count)].elementsEqual(signature) {
                return true
            }
            at += 2 + length
        }
        return false
    }
}
