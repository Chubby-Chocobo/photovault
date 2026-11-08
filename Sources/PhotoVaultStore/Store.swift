import Foundation
import GRDB

public enum StoreError: Error, Equatable, Sendable {
    case corruptRow(table: String, column: String)
    case notFound(String)
}

/// Owns the SQLite database. Repositories are stateless functions that take a `Database`, so the
/// engine composes several of them in one `write {}` transaction.
public final class Store: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Opens (creating if needed) a WAL database at `url`. When `backups` is given and migrations
    /// are pending on an existing database, a backup is taken first (FR-52).
    public static func open(at url: URL, backups: DatabaseBackup? = nil) throws -> Store {
        try open(at: url, backups: backups, migrator: Schema.makeMigrator())
    }

    static func open(at url: URL, backups: DatabaseBackup?, migrator: DatabaseMigrator) throws -> Store {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        let store = Store(writer: pool)
        if let backups {
            let pending = try pool.read { db in
                let completed = try migrator.completedMigrations(db)
                return !completed.isEmpty && migrator.migrations.contains { !completed.contains($0) }
            }
            if pending { _ = try backups.backup(store, now: Date()) }
        }
        try migrator.migrate(pool)
        return store
    }

    /// In-memory database for tests and previews.
    public static func inMemory() throws -> Store {
        let queue = try DatabaseQueue()
        try Schema.makeMigrator().migrate(queue)
        return Store(writer: queue)
    }

    public func read<T>(_ body: (Database) throws -> T) throws -> T {
        try writer.read(body)
    }

    public func write<T>(_ body: (Database) throws -> T) throws -> T {
        try writer.write(body)
    }

    public func read<T: Sendable>(_ body: @Sendable @escaping (Database) throws -> T) async throws -> T {
        try await writer.read(body)
    }

    public func write<T: Sendable>(_ body: @Sendable @escaping (Database) throws -> T) async throws -> T {
        try await writer.write(body)
    }
}
