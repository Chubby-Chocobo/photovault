import Foundation
import PhotoVaultCore

/// Relative-path rules shared by every local operation. Paths are `/`-separated, never absolute,
/// never contain `.` or `..`, and never address the app's own `.photovault` directory.
enum LocalPath {
    static let reservedDirectory = ".photovault"
    static let tmpDirectory = "tmp"
    static let markerName = "destination.json"
    static let connectionTestName = ".photovault-test"

    /// Longest name the app creates (bytes); the filesystem's own limit applies to names it only reads.
    static let createdNameLimit = 255
    /// Capacity of `dirent.d_name`: the longest name `readdir` can hand back for an owner's file.
    static let existingNameLimit = 1023

    /// For names the app creates or renames to.
    static func validate(name: String) throws { try validate(name: name, limit: createdNameLimit) }

    /// For names that already exist on disk (listing, probing, reading): owners may use names longer
    /// than the app would ever write.
    static func validateExisting(name: String) throws { try validate(name: name, limit: existingNameLimit) }

    private static func validate(name: String, limit: Int) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0), name.utf8.count <= limit else {
            throw DestinationError.itemRejected(reason: "invalid name")
        }
    }

    /// Components of a path that addresses existing entries; whatever is created is checked again
    /// with `validate(name:)` where the entry is made.
    static func components(_ path: String) throws -> [String] {
        if path.isEmpty { return [] }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for part in parts { try validateExisting(name: part) }
        return parts
    }

    /// Rejects the reserved directory for operations driven by backup content.
    static func requireUserPath(_ path: String) throws {
        if try components(path).first == reservedDirectory { throw DestinationError.itemRejected(reason: "reserved path") }
    }

    static func join(_ parent: String, _ name: String) -> String { parent.isEmpty ? name : parent + "/" + name }

    static func split(_ path: String) throws -> (parent: String, name: String) {
        let parts = try components(path)
        guard let name = parts.last else { throw DestinationError.itemRejected(reason: "empty path") }
        return (parts.dropLast().joined(separator: "/"), name)
    }

    /// Deepest folder containing both paths.
    static func commonAncestor(_ a: String, _ b: String) -> String {
        let left = a.split(separator: "/"), right = b.split(separator: "/")
        var shared: [Substring] = []
        for (x, y) in zip(left, right) {
            if x != y { break }
            shared.append(x)
        }
        return shared.joined(separator: "/")
    }

    /// `<stem> (conflict-xxxxxx).<ext>`; the suffix comes from the content hash so retries are idempotent.
    static func conflictName(_ name: String, sha256: String) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        return "\(ns.deletingPathExtension) (conflict-\(sha256.prefix(6)))" + (ext.isEmpty ? "" : ".\(ext)")
    }
}
