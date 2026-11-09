import Foundation
import GRDB
import PhotoVaultCore

/// Keeps routine activity from pushing rare events out of the 500 rows kept (FR-63): repeated
/// events of one kind at one destination grow a single row instead of adding rows.
extension ActivityRepository {
    /// `kv` keys holding the row a destination's events of `group` are folded into.
    public static func coalesceKey(_ group: String, _ id: DestinationID) -> String { "activity_row.\(group).\(id.rawValue)" }

    /// Every activity key of a destination, dropped with its other state.
    static func dropKeys(_ db: Database, id: DestinationID) throws {
        try db.execute(sql: "DELETE FROM kv WHERE key LIKE 'activity_row.%' AND key LIKE ?", arguments: ["%.\(id.rawValue)"])
        try KeyValueRepository.set(db, statusRowKey(id), nil)
    }

    /// Adds `count` events to the destination's open row of `group`, or opens a new row when there
    /// is none, it was deleted (trimmed), or `sameWindow` says its start is too old. `message`
    /// gets the total count of the row.
    public static func recordCoalesced(
        _ db: Database, group: String, kind: ActivityKind, destinationId: DestinationID, count: Int, now: Date,
        sameWindow: (Date) -> Bool, message: (Int) -> String
    ) throws {
        guard count > 0 else { return }
        let key = coalesceKey(group, destinationId)
        if let open = try KeyValueRepository.string(db, key).flatMap(OpenRow.init), sameWindow(open.startedAt),
           try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM activity WHERE id = ?)", arguments: [open.rowId]) == true {
            let total = open.count + count
            try db.execute(sql: "UPDATE activity SET at = ?, message = ? WHERE id = ?", arguments: [now, message(total), open.rowId])
            try KeyValueRepository.set(db, key, OpenRow(rowId: open.rowId, count: total, startedAt: open.startedAt).text)
            return
        }
        try record(db, ActivityEvent(at: now, kind: kind, destinationId: destinationId, message: message(count)))
        try KeyValueRepository.set(db, key, OpenRow(rowId: db.lastInsertedRowID, count: count, startedAt: now).text)
    }

    // MARK: Status

    /// A status that returns to what it was within this time is a flap (a retry probe that failed
    /// again, a short network drop): its row is removed instead of adding another.
    public static let statusFlapWindow: TimeInterval = 2 * 3600

    static func statusRowKey(_ id: DestinationID) -> String { "activity_status.\(id.rawValue)" }

    static func recordStatusChange(_ db: Database, id: DestinationID, from old: DestinationStatus, to new: DestinationStatus, now: Date) throws {
        let key = statusRowKey(id)
        if let text = try KeyValueRepository.string(db, key), let last = StatusRow(text),
           now.timeIntervalSince(last.at) < statusFlapWindow, last.from == new.description {
            try db.execute(sql: "DELETE FROM activity WHERE id = ?", arguments: [last.rowId])
            try KeyValueRepository.set(db, key, nil)
            return
        }
        try record(db, ActivityEvent(at: now, kind: .statusChanged, destinationId: id, message: DestinationStatusText.change(from: old, to: new)))
        try KeyValueRepository.set(db, key, StatusRow(rowId: db.lastInsertedRowID, from: old.description, at: now).text)
    }
}

private struct OpenRow {
    var rowId: Int64
    var count: Int
    var startedAt: Date

    init(rowId: Int64, count: Int, startedAt: Date) {
        self.rowId = rowId
        self.count = count
        self.startedAt = startedAt
    }

    init?(_ text: String) {
        let parts = text.split(separator: "|")
        guard parts.count == 3, let id = Int64(parts[0]), let count = Int(parts[1]), let seconds = Double(parts[2]) else { return nil }
        self.init(rowId: id, count: count, startedAt: Date(timeIntervalSince1970: seconds))
    }

    var text: String { "\(rowId)|\(count)|\(startedAt.timeIntervalSince1970)" }
}

private struct StatusRow {
    var rowId: Int64
    var from: String
    var at: Date

    init(rowId: Int64, from: String, at: Date) {
        self.rowId = rowId
        self.from = from
        self.at = at
    }

    init?(_ text: String) {
        let parts = text.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, let id = Int64(parts[0]), let seconds = Double(parts[2]) else { return nil }
        self.init(rowId: id, from: String(parts[1]), at: Date(timeIntervalSince1970: seconds))
    }

    var text: String { "\(rowId)|\(from)|\(at.timeIntervalSince1970)" }
}
