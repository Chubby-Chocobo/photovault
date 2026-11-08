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

    /// Replaces the database at `databaseURL` with the newest readable backup, opens it (running
    /// migrations) and marks every destination `recovery_required` (FR-51/52).
    /// Returns nil when no usable backup exists.
    public func restoreNewest(to databaseURL: URL, now: Date = Date()) throws -> Store? {
        let fm = FileManager.default
        for candidate in try backupFiles() {
            for suffix in ["", "-wal", "-shm"] {
                let path = databaseURL.path + suffix
                if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
            }
            try fm.copyItem(at: candidate.url, to: databaseURL)
            guard let store = try? Store.open(at: databaseURL) else { continue }
            try store.write { try DestinationRepository.markAllRecoveryRequired($0) }
            return store
        }
        return nil
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
