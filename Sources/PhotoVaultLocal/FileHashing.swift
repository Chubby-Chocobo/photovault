import CryptoKit
import Darwin
import Foundation
import PhotoVaultCore

enum FileHashing {
    static let chunkSize = 1 << 20

    /// Streams `fd` from its current offset to EOF.
    static func sha256(fd: Int32) throws -> (hex: String, size: Int64) {
        var hasher = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw ErrorClassifier.destinationError(errno: errno)
            }
            if n == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(n))) }
            total += Int64(n)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), total)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func writeAll(fd: Int32, _ pointer: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < pointer.count {
            let n = write(fd, pointer.baseAddress! + offset, pointer.count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                throw ErrorClassifier.destinationError(errno: errno)
            }
            offset += n
        }
    }
}

/// Incremental SHA-256 with a hex result.
struct StreamingSHA256 {
    private var hasher = SHA256()

    mutating func update(_ bytes: UnsafeRawBufferPointer) { hasher.update(bufferPointer: bytes) }

    mutating func finish() -> String { hasher.finalize().map { String(format: "%02x", $0) }.joined() }
}
