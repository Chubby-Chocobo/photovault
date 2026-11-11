import Foundation
import GRDB
import PhotoVaultCore

/// Reads of the import history: every one-time import with its totals, and its files page by page in path order.
public enum ImportHistoryRepository {
    /// Imports newest first, with files and bytes per item state and the uploads of their files that failed.
    public static func imports(_ db: Database) throws -> [ImportRunRow] {
        let sources = try SourceRepository.fetchAll(db).filter { $0.kind.isImport }.reversed()
        return try sources.map { source in
            var totals: [ImportItemState: OutcomeTotal] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT state, COUNT(*) AS files, COALESCE(SUM(size_bytes), 0) AS bytes FROM import_item WHERE source_id = ? GROUP BY state
                """, arguments: [source.id.rawValue]) {
                guard let state = ImportItemState(rawValue: row["state"]) else { continue }
                totals[state] = OutcomeTotal(files: row["files"], bytes: row["bytes"])
            }
            return ImportRunRow(source: source, totals: totals, failedUploads: try failedUploads(db, sourceId: source.id))
        }
    }

    static func failedUploads(_ db: Database, sourceId: SourceID) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM asset a JOIN upload_job j ON j.asset_key = a.asset_key
            WHERE a.source_id = ? AND j.res_type < 1000 AND j.state IN ('deferred', 'skipped')
            """, arguments: [sourceId.rawValue]) ?? 0
    }

    /// One page of an import's files after `relativePath` (nil = from the first), in path order.
    public static func items(
        _ db: Database, filter: ImportItemFilter, after relativePath: String? = nil, limit: Int = HistoryRepository.pageSize
    ) throws -> [ImportItemRow] {
        let query = itemQuery(filter, after: relativePath, limit: limit)
        return try Row.fetchAll(db, sql: query.sql, arguments: query.arguments).map { row in
            let table = "import_item"
            return ImportItemRow(
                relativePath: try row.require("rel_path", table: table), state: try row.enumValue("state", table: table),
                reason: row["reason"], sizeBytes: row["size_bytes"],
                assetKey: try row.optionalParse("asset_key", table: table) { (raw: String) in AssetKey(rawValue: raw) },
                duplicateOfName: row["duplicate_name"], duplicateOfCapturedAt: row["duplicate_date"])
        }
    }

    /// One state walks `import_item(source_id, state, rel_path)`, none or several walk the primary key; both in path order.
    static func itemQuery(_ filter: ImportItemFilter, after relativePath: String?, limit: Int) -> (sql: String, arguments: StatementArguments) {
        var terms = ["i.source_id = ?"]
        var values: [any DatabaseValueConvertible] = [filter.sourceId.rawValue]
        let states = filter.states.map(\.rawValue).sorted()
        if states.count == 1 {
            terms.append("i.state = ?")
            values += states
        } else if !states.isEmpty {
            terms.append("+i.state IN (\(states.map { _ in "?" }.joined(separator: ", ")))")
            values += states
        }
        if let relativePath {
            terms.append("i.rel_path > ?")
            values.append(relativePath)
        }
        let needle = SearchFolding.fold(filter.search.trimmingCharacters(in: .whitespacesAndNewlines))
        if !needle.isEmpty {
            terms.append("instr(pv_fold(i.rel_path), ?) > 0")
            values.append(needle)
        }
        values.append(limit)
        let sql = """
            SELECT i.rel_path, i.state, i.reason, i.size_bytes, i.asset_key,
                   CASE WHEN i.state = 'duplicate' THEN
                       (SELECT original_filename FROM resource WHERE asset_key = i.asset_key ORDER BY res_type LIMIT 1) END AS duplicate_name,
                   CASE WHEN i.state = 'duplicate' THEN (SELECT creation_date FROM asset WHERE asset_key = i.asset_key) END AS duplicate_date
            FROM import_item i
            WHERE \(terms.joined(separator: " AND "))
            ORDER BY i.rel_path
            LIMIT ?
            """
        return (sql, StatementArguments(values))
    }
}
