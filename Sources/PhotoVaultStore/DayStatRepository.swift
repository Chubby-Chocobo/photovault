import Foundation
import GRDB
import PhotoVaultCore

/// `day_stat` (camera branch only). Counts come from `AssetPlacementRepository.recountDay`.
public enum DayStatRepository {
    public static func fetch(_ db: Database, day: ArchiveDay) throws -> DayStat? {
        try Row.fetchOne(db, sql: "SELECT * FROM day_stat WHERE day = ?", arguments: [day.description]).map(decode)
    }

    public static func fetchAll(_ db: Database) throws -> [DayStat] {
        try Row.fetchAll(db, sql: "SELECT * FROM day_stat ORDER BY day").map(decode)
    }

    /// One-way promotion (8.7): never demotes. Returns true only on the first promotion.
    @discardableResult
    public static func promote(_ db: Database, day: ArchiveDay, now: Date) throws -> Bool {
        try db.execute(sql: """
            UPDATE day_stat SET promoted = 1, promoted_at = ?, place_state = 'pending'
            WHERE day = ? AND promoted = 0
            """, arguments: [now, day.description])
        return db.changesCount > 0
    }

    public static func setPlace(
        _ db: Database, day: ArchiveDay, state: PlaceState, key: String?, name: String?
    ) throws {
        try db.execute(
            sql: "UPDATE day_stat SET place_state = ?, place_key = ?, place_name = ? WHERE day = ?",
            arguments: [state.rawValue, key, name, day.description])
    }

    static func decode(_ row: Row) throws -> DayStat {
        let table = "day_stat"
        return DayStat(
            day: try row.parse("day", table: table) { (raw: String) in ArchiveDay(string: raw) },
            count: row["count"],
            promoted: row["promoted"],
            promotedAt: row["promoted_at"],
            placeKey: row["place_key"],
            placeName: row["place_name"],
            placeState: try row.enumValue("place_state", table: table))
    }
}
