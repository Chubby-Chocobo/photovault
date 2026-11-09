import Foundation
import GRDB
import PhotoVaultCore

/// Placement (fixed once) with collision-free name stems, and `day_stat` recounts.
public enum AssetPlacementRepository {
    /// Allocates `baseStem` (or `baseStem (n)`) for the asset and fixes its placement. Call inside a
    /// write transaction: the writer lock serialises concurrent allocations, so two assets never
    /// receive the same normalized stem. An already placed asset keeps its placement.
    public static func allocatePlacement(
        _ db: Database, assetKey: AssetKey, baseStem: String, category: AssetCategory, day: PlacementDay, now: Date
    ) throws -> Placement {
        guard let asset = try AssetRepository.fetch(db, key: assetKey) else {
            throw StoreError.notFound("asset \(assetKey.rawValue)")
        }
        if let existing = asset.placement { return existing }

        let dayText = day.description
        let baseKey = NameSanitizer.collisionKey(baseStem)
        // Only `base` and `base (n)` can collide with `base`; narrow the scan to that prefix. The prefix
        // length is measured by SQLite (code points), never by Swift's `count` (grapheme clusters).
        let taken = Set(try String.fetchAll(db, sql: """
            SELECT norm_stem FROM name_alloc
            WHERE placement_category = ? AND placement_day = ? AND substr(norm_stem, 1, length(?)) = ?
            """, arguments: [category.rawValue, dayText, baseKey, baseKey]))
        let stem = NameStemBuilder.uniqueStem(base: baseStem, taken: taken)

        try db.execute(sql: """
            INSERT INTO name_alloc (placement_category, placement_day, norm_stem, asset_key) VALUES (?, ?, ?, ?)
            """, arguments: [category.rawValue, dayText, NameSanitizer.collisionKey(stem), assetKey.rawValue])
        try db.execute(sql: """
            UPDATE asset SET placement_category = ?, placement_day = ?, name_stem = ?, placed_at = ?
            WHERE asset_key = ?
            """, arguments: [category.rawValue, dayText, stem, now, assetKey.rawValue])
        return Placement(category: category, day: day, nameStem: stem)
    }

    /// Counts camera assets of `day` from the table (never accumulated) and stores the count,
    /// preserving the promotion and naming state. A placed asset counts in its placement day,
    /// an unplaced one in its creation day.
    @discardableResult
    public static func recountDay(_ db: Database, day: ArchiveDay) throws -> DayStat {
        let text = day.description
        let count = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM asset
            WHERE category = 'camera' AND deleted_at IS NULL
              AND COALESCE(placement_day, creation_day) = ?
            """, arguments: [text]) ?? 0
        try db.execute(sql: """
            INSERT INTO day_stat (day, count) VALUES (?, ?)
            ON CONFLICT(day) DO UPDATE SET count = excluded.count
            """, arguments: [text, count])
        guard let stat = try DayStatRepository.fetch(db, day: day) else { throw StoreError.notFound("day_stat \(text)") }
        return stat
    }
}
