import Foundation
import GRDB
import PhotoVaultCore

/// `day_place`: the extra folders of split camera days. Rows are never deleted one by one
/// (an emptied folder stays); `deleteAll` is for the timezone restore, before any file exists.
public enum DayPlaceRepository {
    public static func fetchAll(_ db: Database, day: ArchiveDay) throws -> [DayPlace] {
        try Row.fetchAll(db, sql: "SELECT * FROM day_place WHERE day = ? ORDER BY slot", arguments: [day.description])
            .map { try decode($0) }
    }

    public static func save(_ db: Database, _ place: DayPlace) throws {
        try db.execute(sql: """
            INSERT INTO day_place (day, slot, place_key, place_name) VALUES (?, ?, ?, ?)
            ON CONFLICT(day, slot) DO UPDATE SET place_key = excluded.place_key, place_name = excluded.place_name
            """, arguments: [place.day.description, place.slot, place.placeKey, place.placeName])
    }

    public static func exists(_ db: Database, day: ArchiveDay) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM day_place WHERE day = ?)", arguments: [day.description]) ?? false
    }

    /// The days that have at least one extra folder.
    public static func days(_ db: Database) throws -> Set<ArchiveDay> {
        let rows = try Row.fetchAll(db, sql: "SELECT DISTINCT day FROM day_place")
        return Set(try rows.map { try $0.parse("day", table: "day_place") { (raw: String) in ArchiveDay(string: raw) } })
    }

    public static func deleteAll(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM day_place")
    }

    static func decode(_ row: Row) throws -> DayPlace {
        let table = "day_place"
        return DayPlace(
            day: try row.parse("day", table: table) { (raw: String) in ArchiveDay(string: raw) },
            slot: try row.require("slot", table: table),
            placeKey: row["place_key"],
            placeName: row["place_name"])
    }
}
