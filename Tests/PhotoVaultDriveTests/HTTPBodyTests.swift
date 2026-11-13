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

    @Test func aFileRangeLoadsExactlyItsBytesAtAnyOffset() throws {
        let (url, data) = try file(3 * 16_384 + 1_000)
        defer { try? FileManager.default.removeItem(at: url) }
        for (offset, length) in [(0, 1), (0, data.count), (16_384, 16_384), (1, 40_000), (16_383, 2), (data.count - 7, 7)] {
            let body = HTTPBody.fileRange(url, offset: Int64(offset), length: length)
            #expect(try body.load() == data.subdata(in: offset..<offset + length), "offset \(offset), length \(length)")
        }
    }

    @Test func aRangePastTheEndIsReadAsBeforeAndAMissingFileThrows() throws {
        let (url, data) = try file(10_000)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(HTTPBody.mapped(url, offset: 9_000, length: 2_000) == nil, "not mapped past the end")
        #expect(try HTTPBody.fileRange(url, offset: 9_000, length: 2_000).load() == data.subdata(in: 9_000..<10_000))
        #expect(try HTTPBody.fileRange(url, offset: 0, length: 0).load().isEmpty)
        #expect(throws: (any Error).self) { try HTTPBody.fileRange(url.appendingPathExtension("gone"), offset: 0, length: 1).load() }
    }
}
