import Foundation
import GRDB
import PhotoVaultCore

public enum StoreError: Error, Equatable, Sendable {
    case corruptRow(table: String, column: String)
    case notFound(String)
    /// The database was written by a newer build; opening it here could corrupt data this build cannot see.
    case newerSchema
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
        configuration.maximumReaderCount = maximumReaderCount
        configuration.prepareDatabase { db in
            try Self.makeDurable(db)
            try db.execute(sql: "PRAGMA cache_size = \(Self.cacheSizeKiB)")
            Self.addFunctions(db)
        }
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        // GRDB sets `synchronous = NORMAL` on the writer after `prepareDatabase`; undo that.
        try pool.writeWithoutTransaction(Self.makeDurable)
        let store = Store(writer: pool)
        if try pool.read(migrator.hasBeenSuperseded) { throw StoreError.newerSchema }
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

    /// Readers open at once (GRDB's default is 5). Reads are short, so a read that finds all three busy waits
    /// briefly; each connection keeps its own page cache.
    static let maximumReaderCount = 3

    /// Page cache per connection, as SQLite's negative "KiB" form (SQLite's default is 2000 KiB). The database is
    /// small and the system keeps its file in its own cache, so a cache miss costs a read, not a disk access.
    static let cacheSizeKiB = -1024

    /// Gives back the memory SQLite holds for caches: the writer drops its page and statement caches once it is
    /// free, and the readers close once they are (the next read opens one again). Nothing waits for it.
    public func releaseMemoryEventually() {
        if let pool = writer as? DatabasePool { pool.releaseMemoryEventually() }
    }

    /// Reservations are committed before the side effect they guard; they must survive power loss
    /// and a kernel panic (NFR-01). macOS needs F_FULLFSYNC for the data to reach the disk.
    @Sendable private static func makeDurable(_ db: Database) throws {
        try db.execute(sql: "PRAGMA synchronous = FULL")
        try db.execute(sql: "PRAGMA fullfsync = ON")
        try db.execute(sql: "PRAGMA checkpoint_fullfsync = ON")
    }

    /// SQL functions the queries use: `pv_fold(text)` is `SearchFolding.fold`, for case- and diacritic-insensitive search.
    @Sendable static func addFunctions(_ db: Database) {
        db.add(function: DatabaseFunction("pv_fold", argumentCount: 1, pure: true) { values in
            (String.fromDatabaseValue(values[0])).map(SearchFolding.fold)
        })
    }

    /// In-memory database for tests and previews.
    public static func inMemory() throws -> Store {
        var configuration = Configuration()
        configuration.prepareDatabase { db in Self.addFunctions(db) }
        let queue = try DatabaseQueue(configuration: configuration)
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
