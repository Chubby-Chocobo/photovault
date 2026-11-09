import CryptoKit
import Foundation
import os
import PhotoVaultCore

/// Writes export chunks to disk and hashes them (MD5 + SHA-256) inline, in delivery order.
///
/// PhotoKit calls its data handler serially; each chunk is written and hashed in that call, with no
/// hop to another task, so order is preserved by construction. The lock only guards against a
/// concurrent `finish`/`abort` from another thread.
final class StreamingFileWriter: @unchecked Sendable {
    enum Failure: Error, Equatable {
        /// `ExportControl` asked to stop (disk guard or caller cancel).
        case stopped
        case io(code: Int, domain: String)
    }

    private struct State {
        var handle: FileHandle?
        var md5 = Insecure.MD5()
        var sha256 = SHA256()
        var size: Int64 = 0
        var failure: Failure?
    }

    let url: URL
    private let control: ExportControl?
    private let state: OSAllocatedUnfairLock<State>

    /// Creates (truncating) the file at `url`; the parent directory must exist.
    init(url: URL, control: ExportControl?) throws {
        self.url = url
        self.control = control
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw Failure.io(code: Int(CocoaError.fileWriteUnknown.rawValue), domain: NSCocoaErrorDomain)
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            state = OSAllocatedUnfairLock(uncheckedState: State(handle: handle))
        } catch {
            let ns = error as NSError
            throw Failure.io(code: ns.code, domain: ns.domain)
        }
    }

    /// Appends one chunk. Returns `false` when the export must stop (I/O failure or control stop);
    /// `failure` then says why and the caller should cancel the PhotoKit request.
    func append(_ data: Data) -> Bool {
        let wrote = state.withLock { s -> Bool in
            guard s.failure == nil, let handle = s.handle else { return false }
            do {
                try handle.write(contentsOf: data)
            } catch {
                let ns = error as NSError
                s.failure = .io(code: ns.code, domain: ns.domain)
                return false
            }
            s.md5.update(data: data)
            s.sha256.update(data: data)
            s.size += Int64(data.count)
            return true
        }
        guard wrote else { return false }
        if let control, !control.record(bytes: data.count) {
            state.withLock { $0.failure = $0.failure ?? .stopped }
            return false
        }
        return true
    }

    var failure: Failure? { state.withLock { $0.failure } }

    /// Closes the file and returns its hashes. Deletes the file and throws if any chunk failed.
    func finish() throws -> ExportedFile {
        let result = state.withLock { s -> (Failure?, Int64, String, String) in
            try? s.handle?.close()
            s.handle = nil
            let md5 = Self.hex(s.md5.finalize())
            let sha = Self.hex(s.sha256.finalize())
            return (s.failure, s.size, md5, sha)
        }
        if let failure = result.0 {
            try? FileManager.default.removeItem(at: url)
            throw failure
        }
        return ExportedFile(url: url, size: result.1, md5: result.2, sha256: result.3)
    }

    /// Closes and deletes the partial file. Safe to call repeatedly or after `finish`.
    func abort() {
        state.withLock { s in
            try? s.handle?.close()
            s.handle = nil
            s.failure = s.failure ?? .stopped
        }
        try? FileManager.default.removeItem(at: url)
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// In-memory SHA-256 of a streamed resource (adjustment data).
final class StreamingSHA256: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(uncheckedState: SHA256())
    private let total = OSAllocatedUnfairLock(initialState: 0)

    func append(_ data: Data) {
        state.withLock { $0.update(data: data) }
        total.withLock { $0 += data.count }
    }

    var byteCount: Int { total.withLock { $0 } }

    func hexDigest() -> String {
        state.withLock { $0.finalize() }.map { String(format: "%02x", $0) }.joined()
    }
}
