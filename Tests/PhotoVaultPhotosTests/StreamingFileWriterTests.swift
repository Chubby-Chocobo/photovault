import CryptoKit
import Dispatch
import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultPhotos

struct StreamingFileWriterTests {
    private func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }

    @Test func knownVectors() throws {
        let url = TestImages.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try StreamingFileWriter(url: url, control: nil)
        #expect(writer.append(Data("a".utf8)))
        #expect(writer.append(Data("bc".utf8)))
        let file = try writer.finish()
        #expect(file.md5 == "900150983cd24fb0d6963f7d28e17f72")
        #expect(file.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(file.size == 3)
    }

    @Test func emptyFile() throws {
        let url = TestImages.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try StreamingFileWriter(url: url, control: nil).finish()
        #expect(file.md5 == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(file.size == 0)
    }

    /// Chunks are produced on hops across a concurrent queue (as PhotoKit's callbacks may be); the
    /// writer must still emit them in delivery order, byte for byte (FR-22).
    @Test func roundTripKeepsOrderAndHashes() async throws {
        var source = Data(count: 3_000_037)
        source.withUnsafeMutableBytes { buffer in
            var generator = SystemRandomNumberGenerator()
            for index in 0..<buffer.count { buffer[index] = UInt8.random(in: 0...255, using: &generator) }
        }
        let chunks = TestImages.chunks(source, size: 4_099)
        let url = TestImages.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try StreamingFileWriter(url: url, control: ExportControl())
        let queue = DispatchQueue(label: "producer", attributes: .concurrent)

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            @Sendable func deliver(_ index: Int) {
                guard index < chunks.count else { return done.resume() }
                queue.async {
                    #expect(writer.append(chunks[index]))
                    deliver(index + 1)
                }
            }
            deliver(0)
        }
        let file = try writer.finish()
        #expect(try Data(contentsOf: url) == source)
        #expect(file.size == Int64(source.count))
        #expect(file.md5 == hex(Insecure.MD5.hash(data: source)))
        #expect(file.sha256 == hex(SHA256.hash(data: source)))
    }

    @Test func controlStopDeletesPartialFile() throws {
        let url = TestImages.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let control = ExportControl(checkpointBytes: 10) { _ in false }
        let writer = try StreamingFileWriter(url: url, control: control)
        #expect(writer.append(Data(count: 5)))
        #expect(!writer.append(Data(count: 6)))
        #expect(writer.failure == .stopped)
        #expect(control.isCancelled)
        #expect(throws: StreamingFileWriter.Failure.stopped) { try writer.finish() }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func abortDeletesPartialFileAndRejectsFurtherChunks() throws {
        let url = TestImages.tempURL()
        let writer = try StreamingFileWriter(url: url, control: nil)
        #expect(writer.append(Data(count: 100)))
        writer.abort()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!writer.append(Data(count: 1)))
        writer.abort()
    }

    @Test func externalCancelStopsOnNextChunk() throws {
        let url = TestImages.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let control = ExportControl()
        let writer = try StreamingFileWriter(url: url, control: control)
        #expect(writer.append(Data(count: 1)))
        control.cancel()
        #expect(!writer.append(Data(count: 1)))
        writer.abort()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func unwritableDestinationThrows() {
        let url = URL(fileURLWithPath: "/nonexistent-dir-pv/file.bin")
        #expect(throws: StreamingFileWriter.Failure.self) { try StreamingFileWriter(url: url, control: nil) }
    }

    @Test func streamingSHA256MatchesKnownVector() {
        let hasher = StreamingSHA256()
        hasher.append(Data("ab".utf8))
        hasher.append(Data("c".utf8))
        #expect(hasher.hexDigest() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(hasher.byteCount == 3)
    }
}
