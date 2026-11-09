import Foundation
import GRDB
import PhotoVaultStore

/// The first release put files under `camera/YYYY/MM` (and `screenshot/…`, `saved/…`); the current
/// layout uses one folder per day. Files already at a destination are never moved to bridge the two
/// ("resync, not migrate"), and a database that still points at the old folders would send new
/// sidecars to day folders while their originals stay in month folders. So the engine does nothing
/// for such a database until the owner starts over with a fresh one.
enum LegacyLayout {
    /// Logical paths of the old layout: a year folder under a branch, or anything below it.
    private static let patterns = ["camera", "screenshot", "saved"].flatMap { branch in
        ["\(branch)/[0-9][0-9][0-9][0-9]", "\(branch)/[0-9][0-9][0-9][0-9]/*"]
    }

    static func isPresent(_ db: Database) throws -> Bool {
        let clause = patterns.map { _ in "GLOB ?" }
        let arguments = StatementArguments(patterns)
        for (table, column) in [("upload_job", "remote_logical_parent"), ("remote_folder", "logical_path")] {
            let match = clause.map { "\(column) \($0)" }.joined(separator: " OR ")
            if try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM \(table) WHERE \(match))", arguments: arguments) == true { return true }
        }
        return false
    }

    /// The stored answer; computed and stored on the first call (a fresh database answers "no" and
    /// keeps it, an old one keeps "yes" until it is replaced).
    static func isBlocked(_ store: Store) async throws -> Bool {
        try await store.write { db in
            if let stored = try KeyValueRepository.string(db, KeyValueRepository.Key.legacyLayout) { return stored == "1" }
            let present = try isPresent(db)
            try KeyValueRepository.set(db, KeyValueRepository.Key.legacyLayout, present ? "1" : "0")
            return present
        }
    }
}
