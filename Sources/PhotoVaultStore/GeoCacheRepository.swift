import Foundation
import GRDB
import PhotoVaultCore

/// `geo_cache`, kept forever (FR-84).
public enum GeoCacheRepository {
    public static func fetch(_ db: Database, cell: GeoCell, locale: String) throws -> GeoCacheEntry? {
        try Row.fetchOne(
            db, sql: "SELECT * FROM geo_cache WHERE geo_cell = ? AND locale = ?", arguments: [cell.key, locale]
        ).map { row in
            GeoCacheEntry(
                cell: cell, locale: locale,
                place: GeoPlace(
                    isoCountryCode: row["iso_country"], country: row["country"],
                    administrativeArea: row["administrative_area"], locality: row["locality"]),
                fetchedAt: try row.require("fetched_at", table: "geo_cache"))
        }
    }

    public static func save(_ db: Database, _ entry: GeoCacheEntry) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO geo_cache
                (geo_cell, locale, iso_country, country, administrative_area, locality, fetched_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                entry.cell.key, entry.locale, entry.place.isoCountryCode, entry.place.country,
                entry.place.administrativeArea, entry.place.locality, entry.fetchedAt,
            ])
    }
}
