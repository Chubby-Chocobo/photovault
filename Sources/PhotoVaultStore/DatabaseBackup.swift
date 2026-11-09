import Foundation
import GRDB

/// Rolling `VACUUM INTO` backups (FR-52): every 24 hours and before migrations, newest 7 kept.
public struct DatabaseBackup: Sendable {
    public static let interval: TimeInterval = 24 * 3600
    public static let retainedCount = 7
    private static let prefix = "photovault-"
    private static let suffix = ".sqlite"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Writes a backup now and prunes old ones. Returns the backup URL.
    @discardableResult
    public func backup(_ store: Store, now: Date) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.fileName(for: now))
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        // VACUUM cannot run inside a transaction.
        try store.writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
        }
        try Self.flushToDisk(url)
        try prune()
        return url
    }

    /// Backs up when the newest backup is older than 24 hours (or none exists).
    @discardableResult
    public func backupIfDue(_ store: Store, now: Date) throws -> URL? {
        if let newest = try backupFiles().first, now.timeIntervalSince(newest.date) < Self.interval { return nil }
        return try backup(store, now: now)
    }

    /// Backup URLs, newest first.
    public func existingBackups() throws -> [URL] {
        try backupFiles().map(\.url)
    }

    /// Replaces a corrupt database at `databaseURL` with the newest backup that passes
    /// `integrity_check`, opens it (running migrations) and marks every destination
    /// `recovery_required` (FR-51/52).
    ///
    /// The damaged files (database, `-wal`, `-shm`) are moved aside as `<name>.corrupt-<time>`, never
    /// deleted: they may hold commits newer than any backup. When no backup is usable they are moved
    /// back and nil is returned, leaving the disk as it was.
    public func restoreNewest(to databaseURL: URL, now: Date = Date()) throws -> Store? {
        let fm = FileManager.default
        let suffixes = ["", "-wal", "-shm"]
        let tag = ".corrupt-" + String(Int64((now.timeIntervalSince1970 * 1000).rounded()))
        var movedAside: [(from: String, to: String)] = []
        for suffix in suffixes {
            let path = databaseURL.path + suffix
            guard fm.fileExists(atPath: path) else { continue }
            let aside = databaseURL.path + tag + suffix
            try fm.moveItem(atPath: path, toPath: aside)
            movedAside.append((path, aside))
        }
        for candidate in try backupFiles() {
            try fm.copyItem(at: candidate.url, to: databaseURL)
            if let store = try? Self.openVerified(at: databaseURL) {
                try store.write { try DestinationRepository.markAllRecoveryRequired($0) }
                return store
            }
            for suffix in suffixes { try? fm.removeItem(atPath: databaseURL.path + suffix) }
        }
        for move in movedAside { try fm.moveItem(atPath: move.to, toPath: move.from) }
        return nil
    }

    /// True for the errors that mean the file itself is damaged, as opposed to a full disk, a
    /// permission problem or a lock: only those justify swapping in a backup.
    public static func isCorruption(_ error: Error) -> Bool {
        guard let error = error as? DatabaseError else { return false }
        return error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB
    }

    private static func openVerified(at url: URL) throws -> Store {
        let store = try Store.open(at: url)
        let result = try store.read { db in try String.fetchOne(db, sql: "PRAGMA integrity_check") }
        guard result == "ok" else { throw DatabaseError(resultCode: .SQLITE_CORRUPT, message: "integrity_check failed") }
        return store
    }

    /// `VACUUM INTO` does not sync its output; a backup must survive the power loss it guards against.
    private static func flushToDisk(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(fd) }
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 { throw CocoaError(.fileWriteUnknown) }
    }

    private func prune() throws {
        for stale in try backupFiles().dropFirst(Self.retainedCount) {
            try FileManager.default.removeItem(at: stale.url)
        }
    }

    private func backupFiles() throws -> [(url: URL, date: Date)] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return names.compactMap { name -> (URL, Date)? in
            guard let date = Self.date(fromFileName: name) else { return nil }
            return (directory.appendingPathComponent(name), date)
        }
        .sorted { $0.1 > $1.1 }
    }

    /// Millisecond epoch keeps names sortable and independent of locale/timezone.
    static func fileName(for date: Date) -> String {
        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded())
        return Self.prefix + String(format: "%015lld", millis) + Self.suffix
    }

    static func date(fromFileName name: String) -> Date? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let digits = name.dropFirst(prefix.count).dropLast(suffix.count)
        guard let millis = Int64(digits) else { return nil }
        return Date(timeIntervalSince1970: Double(millis) / 1000)
    }
}
