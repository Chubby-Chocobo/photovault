import Foundation
import GRDB
import PhotoVaultCore

/// Reads of the transfer history. Lists are paged newest first by `(at, id)`; each page walks an index of
/// `transfer_event` (by source or by run) and the other filters apply to the rows that walk reads.
public enum HistoryRepository {
    public static let pageSize = 200

    /// One page of events after `cursor` (nil = from the newest).
    public static func events(
        _ db: Database, filter: TransferEventFilter, after cursor: HistoryCursor? = nil, limit: Int = pageSize
    ) throws -> [TransferEventRow] {
        let query = eventQuery(filter, after: cursor, limit: limit)
        return try Row.fetchAll(db, sql: query.sql, arguments: query.arguments).map(decodeEvent)
    }

    /// The SQL of `events`, also for query-plan tests. Filters that an index must not serve are written as
    /// `+column`, so SQLite keeps the scope index and its order instead of sorting.
    static func eventQuery(_ filter: TransferEventFilter, after cursor: HistoryCursor?, limit: Int) -> (sql: String, arguments: StatementArguments) {
        var terms: [String] = []
        var values: [(any DatabaseValueConvertible)?] = []
        switch filter.scope {
        case .photos:
            terms.append("e.source_id = ?")
            values.append(SourceID.photos.rawValue)
        case .run(let id):
            terms.append("e.run_id = ?")
            values.append(id)
        }
        if let cursor {
            // `at <= ?` bounds the index walk; the rest orders rows of the same time by id.
            terms.append("e.at <= ? AND (e.at < ? OR e.id < ?)")
            values += [cursor.at, cursor.at, cursor.id]
        }
        if let from = filter.from { terms.append("e.at >= ?"); values.append(from) }
        if let until = filter.until { terms.append("e.at < ?"); values.append(until) }
        if let destination = filter.destinationId { terms.append("+e.destination_id = ?"); values.append(destination.rawValue) }
        if !filter.outcomes.isEmpty {
            let outcomes = filter.outcomes.map(\.rawValue).sorted()
            terms.append("+e.outcome IN (\(outcomes.map { _ in "?" }.joined(separator: ", ")))")
            values += outcomes
        }
        let needle = SearchFolding.fold(filter.search.trimmingCharacters(in: .whitespacesAndNewlines))
        if !needle.isEmpty { terms.append("instr(pv_fold(r.original_filename), ?) > 0"); values.append(needle) }
        switch filter.media {
        case .all: break
        case .photo: terms.append("a.media_type = 1 AND COALESCE(r.is_raw, 0) = 0")
        case .video: terms.append("a.media_type = 2")
        case .raw: terms.append("r.is_raw = 1")
        }
        if let from = filter.capturedFrom { terms.append("a.creation_date >= ?"); values.append(from) }
        if let until = filter.capturedUntil { terms.append("a.creation_date < ?"); values.append(until) }
        if filter.deletedFromLibraryOnly { terms.append("a.deleted_at IS NOT NULL") }
        values.append(limit)
        let sql = """
            SELECT e.*, r.original_filename, r.is_raw, a.media_type, a.creation_date, a.deleted_at
            FROM transfer_event e
            LEFT JOIN resource r ON r.asset_key = e.asset_key AND r.res_type = e.res_type
            LEFT JOIN asset a ON a.asset_key = e.asset_key
            WHERE \(terms.joined(separator: " AND "))
            ORDER BY e.at DESC, e.id DESC
            LIMIT ?
            """
        return (sql, StatementArguments(values.map { $0?.databaseValue ?? .null }))
    }

    /// Uploaded and updated files per 15-minute slot (UTC) in `[from, until)`, oldest first. A slot never
    /// straddles a local midnight in any time zone, so the app can sum slots into local days.
    public static func timeline(
        _ db: Database, from: Date, until: Date, destinationId: DestinationID? = nil
    ) throws -> [TimelineSlot] {
        let query = timelineQuery(from: from, until: until, destinationId: destinationId)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return try Row.fetchAll(db, sql: query.sql, arguments: query.arguments).compactMap { row in
            let slot: String = row["slot"]
            guard let start = slotDate(slot, calendar: calendar) else { return nil }
            return TimelineSlot(start: start, files: row["files"], bytes: row["bytes"])
        }
    }

    static func timelineQuery(from: Date, until: Date, destinationId: DestinationID?) -> (sql: String, arguments: StatementArguments) {
        var values: [any DatabaseValueConvertible] = [from, until]
        var destination = ""
        if let destinationId {
            destination = "AND +destination_id = ?"
            values.append(destinationId.rawValue)
        }
        let sql = """
            SELECT strftime('%Y-%m-%d %H:', at) || printf('%02d', (CAST(strftime('%M', at) AS INTEGER) / 15) * 15) AS slot,
                   COUNT(*) AS files, COALESCE(SUM(bytes), 0) AS bytes
            FROM transfer_event
            WHERE outcome IN ('uploaded', 'updated') AND at >= ? AND at < ? \(destination)
            GROUP BY slot ORDER BY slot
            """
        return (sql, StatementArguments(values))
    }

    /// "2026-11-10 23:45" (UTC) to a date.
    static func slotDate(_ slot: String, calendar: Calendar) -> Date? {
        let parts = slot.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" }).compactMap { Int($0) }
        guard parts.count == 5 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4]))
    }

    /// Where each original file of the asset stands at every destination now, with its latest integrity result.
    public static func statuses(_ db: Database, assetKey: AssetKey) throws -> [FileDestinationStatus] {
        try Row.fetchAll(db, sql: """
            SELECT j.destination_id, j.res_type, j.state, j.state_reason, j.last_error, j.remote_id, c.checked_at, c.result
            FROM upload_job j
            LEFT JOIN integrity_check c ON c.destination_id = j.destination_id AND c.asset_key = j.asset_key AND c.res_type = j.res_type
            WHERE j.asset_key = ? AND j.res_type < 1000
            ORDER BY j.destination_id, j.res_type
            """, arguments: [assetKey.rawValue]).map { row in
            let table = "upload_job"
            return FileDestinationStatus(
                destinationId: try row.destinationId("destination_id", table: table),
                resType: ResourceType(rawValue: row["res_type"]), state: try row.enumValue("state", table: table),
                reason: try row.optionalEnum("state_reason", table: table), detail: row["last_error"], remoteId: row["remote_id"],
                checkedAt: row["checked_at"], checkResult: try row.optionalEnum("result", table: "integrity_check"))
        }
    }

    static func decodeEvent(_ row: Row) throws -> TransferEventRow {
        let table = "transfer_event"
        return TransferEventRow(
            id: try row.require("id", table: table), at: try row.require("at", table: table), approximate: row["approximate"],
            jobId: try row.require("job_id", table: table), destinationId: try row.destinationId("destination_id", table: table),
            assetKey: try row.assetKey("asset_key", table: table), resType: ResourceType(rawValue: row["res_type"]),
            sourceId: try row.parse("source_id", table: table) { (raw: String) in SourceID(rawValue: raw) },
            origin: try row.enumValue("origin", table: table), runId: row["run_id"], outcome: try row.enumValue("outcome", table: table),
            bytes: row["bytes"], reason: try row.optionalEnum("reason", table: table), detail: row["detail"],
            fileName: row["original_filename"] ?? "", mediaType: MediaType(rawValue: row["media_type"] ?? 0) ?? .unknown,
            isRaw: row["is_raw"] ?? false, capturedAt: row["creation_date"], deletedFromLibraryAt: row["deleted_at"])
    }
}
