import Foundation
import GRDB
import PhotoVaultCore

/// `import_item` rows: one per file found in a source.
public enum ImportItemRepository {
    /// Re-listing a folder adds only the files that are new; known items keep their state.
    public static func insertIgnoring(_ db: Database, _ items: [ImportItem]) throws {
        let statement = try db.cachedStatement(sql: """
        INSERT OR IGNORE INTO import_item (source_id, rel_path, group_key, uti, size_bytes, created_at_fs, modified_at_fs, state, asset_key, is_primary, date_source, reason)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """)
        for item in items {
            try statement.execute(arguments: [
                item.sourceId.rawValue, item.relativePath, item.groupKey, item.uti, item.sizeBytes, item.createdAtFS,
                item.modifiedAtFS, item.state.rawValue, item.assetKey?.rawValue, item.isPrimary, item.dateSource?.rawValue, item.reason,
            ])
        }
    }

    /// Pending items of up to `limit` whole groups, ordered by group then path. A group is never split.
    /// Groups named in `excluding` are left out, so a group that cannot be read now does not hide the others.
    public static func nextGroups(_ db: Database, sourceId: SourceID, limit: Int, excluding: Set<String> = []) throws -> [[ImportItem]] {
        let skipped = excluding.sorted()
        let marks = skipped.isEmpty ? "" : "AND group_key NOT IN (\(Array(repeating: "?", count: skipped.count).joined(separator: ", ")))"
        var values: [any DatabaseValueConvertible] = [sourceId.rawValue, sourceId.rawValue]
        values += skipped
        values.append(limit)
        let arguments = StatementArguments(values.map(\.databaseValue))
        let rows = try Row.fetchAll(db, sql: """
        SELECT * FROM import_item
        WHERE source_id = ? AND state = 'pending' AND group_key IN (
            SELECT group_key FROM import_item WHERE source_id = ? AND state = 'pending' \(marks)
            GROUP BY group_key ORDER BY group_key LIMIT ?)
        ORDER BY group_key, rel_path
        """, arguments: arguments)
        var groups: [[ImportItem]] = []
        for item in try rows.map(decode) {
            if groups.last?.first?.groupKey == item.groupKey { groups[groups.count - 1].append(item) } else { groups.append([item]) }
        }
        return groups
    }

    public static func mark(
        _ db: Database, sourceId: SourceID, relativePath: String, state: ImportItemState, assetKey: AssetKey?,
        isPrimary: Bool, dateSource: DateSource?, reason: String?
    ) throws {
        try db.execute(sql: """
        UPDATE import_item SET state = ?, asset_key = ?, is_primary = ?, date_source = ?, reason = ?
        WHERE source_id = ? AND rel_path = ?
        """, arguments: [state.rawValue, assetKey?.rawValue, isPrimary, dateSource?.rawValue, reason, sourceId.rawValue, relativePath])
    }

    public static func counts(_ db: Database, sourceId: SourceID) throws -> [ImportItemState: Int] {
        var result: [ImportItemState: Int] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT state, COUNT(*) AS n FROM import_item WHERE source_id = ? GROUP BY state", arguments: [sourceId.rawValue]) {
            let table = "import_item"
            result[try row.enumValue("state", table: table)] = row["n"]
        }
        return result
    }

    /// Returns how many items were still pending.
    @discardableResult
    public static func cancelPending(_ db: Database, sourceId: SourceID) throws -> Int {
        try db.execute(sql: "UPDATE import_item SET state = 'cancelled' WHERE source_id = ? AND state = 'pending'", arguments: [sourceId.rawValue])
        return db.changesCount
    }

    /// The primary file an asset was imported from; `preferring` picks the job when several imported it.
    public static func primary(_ db: Database, assetKey: AssetKey, preferring sourceId: SourceID) throws -> (sourceId: SourceID, relativePath: String, dateSource: DateSource?)? {
        guard let row = try Row.fetchOne(db, sql: """
        SELECT source_id, rel_path, date_source FROM import_item
        WHERE asset_key = ?1 AND is_primary = 1 AND state = 'imported'
        ORDER BY source_id = ?2 DESC, rowid DESC LIMIT 1
        """, arguments: [assetKey.rawValue, sourceId.rawValue]) else { return nil }
        let table = "import_item"
        return (
            try row.parse("source_id", table: table) { (raw: String) in SourceID(rawValue: raw) },
            try row.require("rel_path", table: table),
            try row.optionalEnum("date_source", table: table))
    }

    static func decode(_ row: Row) throws -> ImportItem {
        let table = "import_item"
        return ImportItem(
            sourceId: try row.parse("source_id", table: table) { (raw: String) in SourceID(rawValue: raw) },
            relativePath: try row.require("rel_path", table: table),
            groupKey: try row.require("group_key", table: table),
            uti: try row.require("uti", table: table),
            sizeBytes: try row.require("size_bytes", table: table),
            createdAtFS: row["created_at_fs"],
            modifiedAtFS: row["modified_at_fs"],
            state: try row.enumValue("state", table: table),
            assetKey: try row.optionalParse("asset_key", table: table) { (raw: String) in AssetKey(rawValue: raw) },
            isPrimary: row["is_primary"],
            dateSource: try row.optionalEnum("date_source", table: table),
            reason: row["reason"])
    }
}
