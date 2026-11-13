import Foundation
import Testing
@testable import PhotoVaultDrive

@Suite struct HTTPBodyTests {
    private func file(_ size: Int) throws -> (URL, Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("body-\(UUID().uuidString)")
        let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 251) })
        try data.write(to: url)
        return (url, data)
    }

    @Test func aFileRangeLoadsExactlyItsBytesAtAnyOffsetMappedOrRead() throws {
        let (url, data) = try file(3 * 16_384 + 1_000)
        defer { try? FileManager.default.removeItem(at: url) }
        for (offset, length) in [(0, 1), (0, data.count), (16_384, 16_384), (1, 40_000), (16_383, 2), (data.count - 7, 7)] {
            let expected = data.subdata(in: offset..<offset + length)
            for mappable in [true, false] {
                let body = HTTPBody.fileRange(url, offset: Int64(offset), length: length, mappable: mappable)
                #expect(try body.load() == expected, "offset \(offset), length \(length), mappable \(mappable)")
            }
        }
    }

    @Test func rangesInsideTheFileAreMappedAlignedOrNot() throws {
        let (url, data) = try file(3 * 16_384 + 1_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let aligned = try #require(HTTPBody.mapped(url, offset: 16_384, length: 16_384), "an aligned range is mapped")
        #expect(aligned == data.subdata(in: 16_384..<32_768))
        let unaligned = try #require(HTTPBody.mapped(url, offset: 1_001, length: 20_000), "an unaligned range is mapped")
        #expect(unaligned == data.subdata(in: 1_001..<21_001))
    }

    @Test func aRangePastTheEndIsReadAsBeforeAndAMissingFileThrows() throws {
        let (url, data) = try file(10_000)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(HTTPBody.mapped(url, offset: 9_000, length: 2_000) == nil, "not mapped past the end")
        #expect(try HTTPBody.fileRange(url, offset: 9_000, length: 2_000, mappable: true).load() == data.subdata(in: 9_000..<10_000))
        #expect(try HTTPBody.fileRange(url, offset: 0, length: 0, mappable: true).load().isEmpty)
        #expect(throws: (any Error).self) { try HTTPBody.fileRange(url.appendingPathExtension("gone"), offset: 0, length: 1, mappable: true).load() }
    }

    @Test func onlyFilesOnAnInternalLocalVolumeAreMapped() {
        #expect(HTTPBody.mayMap(volumeIsLocal: true, volumeIsInternal: true))
        #expect(!HTTPBody.mayMap(volumeIsLocal: true, volumeIsInternal: false), "an external disk can be unplugged")
        #expect(!HTTPBody.mayMap(volumeIsLocal: false, volumeIsInternal: true), "a network volume can drop out")
        #expect(!HTTPBody.mayMap(volumeIsLocal: false, volumeIsInternal: false))
        #expect(!HTTPBody.mayMap(volumeIsLocal: nil, volumeIsInternal: true), "unknown counts as no")
        #expect(!HTTPBody.mayMap(volumeIsLocal: true, volumeIsInternal: nil), "unknown counts as no")
        #expect(!HTTPBody.mayMap(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")), "a file that cannot be asked is read")
    }
}
