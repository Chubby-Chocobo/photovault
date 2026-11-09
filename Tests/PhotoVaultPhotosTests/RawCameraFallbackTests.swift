import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultPhotos

/// The file's own camera names, for RAW files ImageIO cannot read. Built from synthetic bytes so the
/// result does not depend on which cameras the installed macOS knows.
struct RawCameraFallbackTests {
    /// A TIFF header and one directory with Make and Model; `magic` stands in for format variants.
    private func tiff(make: String, model: String, littleEndian: Bool = true, magic: UInt16 = 42,
                      nextDirectory: [UInt8]? = nil) -> Data {
        func u16(_ v: UInt16) -> [UInt8] { littleEndian ? [UInt8(v & 0xFF), UInt8(v >> 8)] : [UInt8(v >> 8), UInt8(v & 0xFF)] }
        func u32(_ v: UInt32) -> [UInt8] { littleEndian ? u16(UInt16(v & 0xFFFF)) + u16(UInt16(v >> 16)) : u16(UInt16(v >> 16)) + u16(UInt16(v & 0xFFFF)) }
        let makeBytes = Array(make.utf8) + [0], modelBytes = Array(model.utf8) + [0]
        let directoryAt: UInt32 = 8, entries = 2
        let valuesAt = Int(directoryAt) + 2 + entries * 12 + 4
        func entry(_ tag: UInt16, _ value: [UInt8], at offset: Int) -> [UInt8] {
            let field = value.count <= 4 ? value + [UInt8](repeating: 0, count: 4 - value.count) : u32(UInt32(offset))
            return u16(tag) + u16(2) + u32(UInt32(value.count)) + field
        }
        let makeAt = valuesAt, modelAt = valuesAt + (makeBytes.count > 4 ? makeBytes.count : 0)
        var bytes = (littleEndian ? [0x49, 0x49] : [0x4D, 0x4D]) + u16(magic) + u32(directoryAt)
        bytes += u16(UInt16(entries)) + entry(0x010F, makeBytes, at: makeAt) + entry(0x0110, modelBytes, at: modelAt)
        let next = nextDirectory == nil ? 0 : UInt32(modelAt + (modelBytes.count > 4 ? modelBytes.count : 0))
        bytes += u32(next)
        if makeBytes.count > 4 { bytes += makeBytes }
        if modelBytes.count > 4 { bytes += modelBytes }
        if let nextDirectory { bytes += nextDirectory }
        return Data(bytes)
    }

    @Test func littleEndianTiffDirectory() {
        let found = RawCameraFallback.metadata(in: tiff(make: "SONY", model: "ILCE-9M3"))
        #expect(found == CaptureMetadata(make: "SONY", model: "ILCE-9M3"))
    }

    @Test func bigEndianTiffDirectory() {
        let found = RawCameraFallback.metadata(in: tiff(make: "NIKON CORPORATION", model: "NIKON Z 5_2", littleEndian: false))
        #expect(found == CaptureMetadata(make: "NIKON CORPORATION", model: "NIKON Z 5_2"))
    }

    /// Values of four bytes or less sit inside the entry; ORF and RW2 use other magic numbers.
    @Test func shortValuesAndOtherMagicNumbers() {
        #expect(RawCameraFallback.metadata(in: tiff(make: "DJI", model: "FC1", magic: 0x4F52))
            == CaptureMetadata(make: "DJI", model: "FC1"))
        #expect(RawCameraFallback.metadata(in: tiff(make: "Panasonic", model: "DC-S9", magic: 0x0055))
            == CaptureMetadata(make: "Panasonic", model: "DC-S9"))
    }

    @Test func padsAndNullsAreTrimmed() {
        let found = RawCameraFallback.metadata(in: tiff(make: "Hasselblad  ", model: " CFV 100C"))
        #expect(found == CaptureMetadata(make: "Hasselblad", model: "CFV 100C"))
    }

    /// A directory that points at itself must not loop.
    @Test func aDirectoryChainThatLoopsEnds() {
        var bytes = [UInt8](tiff(make: "X", model: "Y"))
        // Next-directory offset of IFD0 (after 2 entries) back to IFD0.
        let nextAt = 8 + 2 + 2 * 12
        bytes.replaceSubrange(nextAt..<(nextAt + 4), with: [8, 0, 0, 0])
        #expect(RawCameraFallback.metadata(in: Data(bytes)) == CaptureMetadata(make: "X", model: "Y"))
    }

    @Test func truncatedOrForeignBytesGiveNothing() {
        let full = tiff(make: "SONY", model: "ILCE-1M2")
        for length in [0, 3, 8, 12, 30] {
            let found = RawCameraFallback.metadata(in: full.prefix(length))
            #expect(found == nil || found?.make == "SONY", "\(length) bytes")
        }
        #expect(RawCameraFallback.metadata(in: Data(repeating: 0xAB, count: 4096)) == nil)
        #expect(RawCameraFallback.metadata(in: Data("FUJIFILMCCD-RAW 0201".utf8)) == nil)
    }

    /// CR3: an ISO media file whose CMT1 box carries the TIFF directory.
    @Test func canonCMT1Box() {
        var data = Data([0, 0, 0, 0x18]) + Data("ftypcrx ".utf8) + Data(repeating: 0, count: 12)
        let tiffBlock = tiff(make: "Canon", model: "Canon EOS R1")
        data += Data([0, 0, 0, UInt8(8 + tiffBlock.count)]) + Data("CMT1".utf8) + tiffBlock
        #expect(RawCameraFallback.metadata(in: data) == CaptureMetadata(make: "Canon", model: "Canon EOS R1"))
    }

    /// RAF and others: a JPEG preview with an Exif block after a proprietary header.
    @Test func embeddedJpegPreview() throws {
        let jpeg = try #require(TestImages.make(type: .jpeg, spec: TestImages.Spec(make: "FUJIFILM", model: "X-E5", lens: "XF23mm")))
        let data = Data("FUJIFILMCCD-RAW 0201FF383501".utf8) + Data(repeating: 0, count: 120) + jpeg
        let found = RawCameraFallback.metadata(in: data)
        #expect(found?.make == "FUJIFILM")
        #expect(found?.model == "X-E5")
        #expect(found?.lensModel == "XF23mm")
    }

    /// End to end: the reader falls back for a RAW type ImageIO cannot parse, and only for RAW.
    @Test func theReaderFallsBackForRawOnly() throws {
        let jpeg = try #require(TestImages.make(type: .jpeg, spec: TestImages.Spec(make: "FUJIFILM", model: "X-E5")))
        let url = TestImages.tempURL(UUID().uuidString)
        try (Data("FUJIFILMCCD-RAW 0201FF383501".utf8) + Data(repeating: 0, count: 120) + jpeg).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let raw = ImageIOMetadataReader().metadata(of: url, uti: "com.fuji.raw-image", mediaType: .image)
        #expect(raw.make == "FUJIFILM" && raw.model == "X-E5")
        let notRaw = ImageIOMetadataReader().metadata(of: url, uti: "public.data", mediaType: .image)
        #expect(!notRaw.hasCameraIdentity)
    }
}
