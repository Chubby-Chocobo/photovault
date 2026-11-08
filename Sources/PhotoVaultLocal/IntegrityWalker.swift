import CryptoKit
import Darwin
import Foundation
import PhotoVaultCore

/// A file the database says should be at the destination.
public struct ExpectedFile: Hashable, Sendable {
    public var path: String
    public var size: Int64
    /// SHA-256 the app wrote; files without one are never re-hashed.
    public var sha256: String?

    public init(path: String, size: Int64, sha256: String?) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

public struct IntegrityReport: Hashable, Sendable {
    public var missing: [String] = []
    public var sizeMismatch: [String] = []
    public var hashMismatch: [String] = []
    /// Paths that could not be checked safely (symlinks, other volumes).
    public var rejected: [String] = []
    public var hashedCount = 0
    public var hashedBytes: Int64 = 0

    public var isClean: Bool { missing.isEmpty && sizeMismatch.isEmpty && hashMismatch.isEmpty && rejected.isEmpty }
}

/// Tree integrity check (FR-76): path + size of every expected file, plus a re-hash of a deterministic
/// 1 % sample capped at 5 GB per run to catch bit rot. Read-only.
public enum IntegrityWalker {
    public static let sampleFraction = 0.01
    public static let sampleByteCap: Int64 = 5 * 1024 * 1024 * 1024

    /// Deterministic for a given seed: files are ranked by `SHA-256(seed, path)`; a different seed
    /// (e.g. the run date) rotates the sample so the whole archive is covered over time.
    public static func sample(_ files: [ExpectedFile], seed: String, fraction: Double = sampleFraction,
                              byteCap: Int64 = sampleByteCap) -> [ExpectedFile] {
        let eligible = files.filter { $0.sha256 != nil }
        guard !eligible.isEmpty else { return [] }
        let wanted = max(1, Int((Double(eligible.count) * fraction).rounded(.up)))
        let ranked = eligible
            .map { (file: $0, rank: SHA256.hash(data: Data((seed + "\u{0}" + $0.path).utf8)).map { String(format: "%02x", $0) }.joined()) }
            .sorted { ($0.rank, $0.file.path) < ($1.rank, $1.file.path) }
        var chosen: [ExpectedFile] = []
        var bytes: Int64 = 0
        for entry in ranked where chosen.count < wanted {
            guard bytes + entry.file.size <= byteCap else { continue }
            chosen.append(entry.file)
            bytes += entry.file.size
        }
        return chosen
    }

    static func run(root: DirectoryHandle, expected: [ExpectedFile], seed: String) throws -> IntegrityReport {
        var report = IntegrityReport()
        let sampled = Set(sample(expected, seed: seed).map(\.path))
        var parents: [String: DirectoryHandle?] = [:]
        for file in expected {
            if Task.isCancelled { break }
            do {
                try LocalPath.requireUserPath(file.path)
                let (parentPath, name) = try LocalPath.split(file.path)
                if parents[parentPath] == nil {
                    do { parents[parentPath] = .some(try root.openDirectory(parentPath)) } catch DestinationError.notFound { parents[parentPath] = .some(nil) }
                }
                guard let parent = parents[parentPath] ?? nil, let st = try parent.status(name) else {
                    report.missing.append(file.path)
                    continue
                }
                if st.isSymlink || !st.isRegular {
                    report.rejected.append(file.path)
                } else if Int64(st.st_size) != file.size {
                    report.sizeMismatch.append(file.path)
                } else if sampled.contains(file.path), let expectedHash = file.sha256 {
                    let fd = try parent.openFile(name)
                    defer { close(fd) }
                    let hash = try FileHashing.sha256(fd: fd)
                    report.hashedCount += 1
                    report.hashedBytes += hash.size
                    if hash.hex != expectedHash { report.hashMismatch.append(file.path) }
                }
            } catch DestinationError.itemRejected {
                report.rejected.append(file.path)
            }
        }
        return report
    }
}

extension LocalFileOps {
    func verifyIntegrity(expected: [ExpectedFile], seed: String) throws -> IntegrityReport {
        try withRoot { try IntegrityWalker.run(root: $0, expected: expected, seed: seed) }
    }
}
