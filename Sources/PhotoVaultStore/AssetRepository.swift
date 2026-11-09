import Foundation
import GRDB
import PhotoVaultCore

/// `asset`, `asset_alias`, `album_member`, name allocation and day-stat recounts.
public enum AssetRepository {
    // MARK: Upsert

    /// Inserts or updates the scan-owned fields of an asset. Placement, `placed_at` and
    /// `first_seen_at` are never overwritten here (placement is fixed once, spec 8.1).
    /// `creationDay` is computed in the archive timezone `timeZone` at write time.
    public static func upsert(_ db: Database, _ asset: AssetRecord, timeZone: TimeZone) throws {
        let day = asset.creationDate.map { ArchiveDay(date: $0, timeZone: timeZone).description }
        try db.execute(sql: """
        INSERT INTO asset (
            asset_key, asset_key_hash, local_id, cloud_id, creation_date, creation_day, modification_date,
            media_type, media_subtypes, category, category_reason, category_provisional,
            placement_category, placement_day, name_stem, placed_at, is_hidden, is_favorite,
            burst_identifier, burst_is_pick, location_lat, location_lon, geo_cell, pixel_width, pixel_height,
            duration, camera_make, camera_model, lens_model, has_adjustments, adjustment_hash,
            edit_check_pending, inserted_at, first_seen_at, last_seen_at, deleted_at)
        VALUES (
            :asset_key, :asset_key_hash, :local_id, :cloud_id, :creation_date, :creation_day, :modification_date,
            :media_type, :media_subtypes, :category, :category_reason, :category_provisional,
            :placement_category, :placement_day, :name_stem, :placed_at, :is_hidden, :is_favorite,
            :burst_identifier, :burst_is_pick, :location_lat, :location_lon, :geo_cell, :pixel_width, :pixel_height,
            :duration, :camera_make, :camera_model, :lens_model, :has_adjustments, :adjustment_hash,
            :edit_check_pending, :inserted_at, :first_seen_at, :last_seen_at, :deleted_at)
        ON CONFLICT(asset_key) DO UPDATE SET
            local_id = excluded.local_id, cloud_id = excluded.cloud_id,
            creation_date = excluded.creation_date, creation_day = excluded.creation_day,
            modification_date = excluded.modification_date, media_type = excluded.media_type,
            media_subtypes = excluded.media_subtypes, category = excluded.category,
            category_reason = excluded.category_reason, category_provisional = excluded.category_provisional,
            is_hidden = excluded.is_hidden, is_favorite = excluded.is_favorite,
            burst_identifier = excluded.burst_identifier, burst_is_pick = excluded.burst_is_pick,
            location_lat = excluded.location_lat, location_lon = excluded.location_lon,
            geo_cell = excluded.geo_cell, pixel_width = excluded.pixel_width,
            pixel_height = excluded.pixel_height, duration = excluded.duration,
            camera_make = excluded.camera_make, camera_model = excluded.camera_model,
            lens_model = excluded.lens_model, has_adjustments = excluded.has_adjustments,
            adjustment_hash = excluded.adjustment_hash, edit_check_pending = excluded.edit_check_pending,
            inserted_at = COALESCE(asset.inserted_at, excluded.inserted_at),
            last_seen_at = excluded.last_seen_at, deleted_at = excluded.deleted_at
        """, arguments: [
            "asset_key": asset.assetKey.rawValue, "asset_key_hash": asset.assetKey.sha256Hex,
            "local_id": asset.localId, "cloud_id": asset.cloudId, "creation_date": asset.creationDate,
            "creation_day": day, "modification_date": asset.modificationDate,
            "media_type": asset.mediaType.rawValue, "media_subtypes": Int64(asset.mediaSubtypes.rawValue),
            "category": asset.category?.rawValue, "category_reason": asset.categoryReason?.rawValue,
            "category_provisional": asset.categoryProvisional,
            "placement_category": asset.placement?.category.rawValue,
            "placement_day": asset.placement?.day.description, "name_stem": asset.placement?.nameStem,
            "placed_at": asset.placedAt, "is_hidden": asset.isHidden, "is_favorite": asset.isFavorite,
            "burst_identifier": asset.burstIdentifier, "burst_is_pick": asset.burstIsPick,
            "location_lat": asset.location?.latitude, "location_lon": asset.location?.longitude,
            "geo_cell": asset.geoCell?.key, "pixel_width": asset.pixelWidth, "pixel_height": asset.pixelHeight,
            "duration": asset.duration, "camera_make": asset.cameraMake, "camera_model": asset.cameraModel,
            "lens_model": asset.lensModel, "has_adjustments": asset.hasAdjustments,
            "adjustment_hash": asset.adjustmentHash, "edit_check_pending": asset.editCheckPending,
            "inserted_at": asset.insertedAt, "first_seen_at": asset.firstSeenAt,
            "last_seen_at": asset.lastSeenAt, "deleted_at": asset.deletedAt,
        ])
    }

    /// Recomputes `creation_day` for every asset after the archive timezone changed.
    public static func recomputeCreationDays(_ db: Database, timeZone: TimeZone) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT asset_key, creation_date FROM asset WHERE creation_date IS NOT NULL")
        for row in rows {
            let date: Date = row["creation_date"]
            try db.execute(
                sql: "UPDATE asset SET creation_day = ? WHERE asset_key = ?",
                arguments: [ArchiveDay(date: date, timeZone: timeZone).description, row["asset_key"] as String])
        }
    }

    // MARK: Lookup

    public static func fetch(_ db: Database, key: AssetKey) throws -> AssetRecord? {
        try Row.fetchOne(db, sql: "SELECT * FROM asset WHERE asset_key = ?", arguments: [key.rawValue]).map(decode)
    }

    public static func fetch(_ db: Database, keys: [AssetKey]) throws -> [AssetRecord] {
        try keys.compactMap { try fetch(db, key: $0) }
    }

    /// Re-attach lookup (8.1): by `local_id`, then alias, then `cloud_id`.
    public static func find(_ db: Database, localId: String?, cloudId: String?) throws -> AssetRecord? {
        if let localId {
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM asset WHERE local_id = ?", arguments: [localId]) {
                return try decode(row)
            }
            if let row = try Row.fetchOne(db, sql: """
                SELECT a.* FROM asset a JOIN asset_alias l ON l.asset_key = a.asset_key WHERE l.alias = ?
                """, arguments: [localId]) {
                return try decode(row)
            }
        }
        if let cloudId {
            if let row = try Row.fetchOne(
                db, sql: "SELECT * FROM asset WHERE cloud_id = ? ORDER BY first_seen_at LIMIT 1", arguments: [cloudId]) {
                return try decode(row)
            }
            if let row = try Row.fetchOne(db, sql: """
                SELECT a.* FROM asset a JOIN asset_alias l ON l.asset_key = a.asset_key WHERE l.alias = ?
                """, arguments: [cloudId]) {
                return try decode(row)
            }
        }
        return nil
    }

    /// Lookup for `h:` hashed keys (first 32 hex characters of the SHA-256).
    public static func fetch(_ db: Database, hashPrefix: String) throws -> [AssetRecord] {
        try Row.fetchAll(
            db, sql: "SELECT * FROM asset WHERE substr(asset_key_hash, 1, ?) = ?",
            arguments: [hashPrefix.count, hashPrefix]).map(decode)
    }

    /// Cloud-id backfill (FR-53): assets keyed by local id that have no `cloud_id` yet.
    public static func fetchMissingCloudId(_ db: Database, limit: Int) throws -> [AssetRecord] {
        try Row.fetchAll(
            db, sql: "SELECT * FROM asset WHERE cloud_id IS NULL AND deleted_at IS NULL LIMIT ?",
            arguments: [limit]).map(decode)
    }

    public static func count(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0
    }

    // MARK: Aliases and albums

    public static func addAlias(_ db: Database, alias: String, to key: AssetKey) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO asset_alias (alias, asset_key) VALUES (?, ?)",
            arguments: [alias, key.rawValue])
    }

    public static func aliases(_ db: Database, of key: AssetKey) throws -> [AssetAlias] {
        try Row.fetchAll(db, sql: "SELECT * FROM asset_alias WHERE asset_key = ? ORDER BY alias", arguments: [key.rawValue])
            .map { AssetAlias(alias: $0["alias"], assetKey: try $0.assetKey("asset_key", table: "asset_alias")) }
    }

    /// Replaces the album membership of one asset.
    public static func setAlbums(_ db: Database, for key: AssetKey, members: [AlbumMember]) throws {
        try db.execute(sql: "DELETE FROM album_member WHERE asset_key = ?", arguments: [key.rawValue])
        for member in members {
            try db.execute(
                sql: "INSERT OR REPLACE INTO album_member (album_local_id, album_title, asset_key) VALUES (?, ?, ?)",
                arguments: [member.albumLocalId, member.albumTitle, key.rawValue])
        }
    }

    public static func albums(_ db: Database, for key: AssetKey) throws -> [AlbumMember] {
        try Row.fetchAll(
            db, sql: "SELECT * FROM album_member WHERE asset_key = ? ORDER BY album_local_id", arguments: [key.rawValue]
        ).map {
            AlbumMember(albumLocalId: $0["album_local_id"], albumTitle: $0["album_title"], assetKey: key)
        }
    }

    // MARK: Decoding

    static func decode(_ row: Row) throws -> AssetRecord {
        let table = "asset"
        var placement: Placement?
        if let category: AssetCategory = try row.optionalEnum("placement_category", table: table) {
            placement = Placement(
                category: category,
                day: try row.parse("placement_day", table: table) { (raw: String) in PlacementDay(string: raw) },
                nameStem: try row.require("name_stem", table: table))
        }
        var location: GeoPoint?
        if let lat: Double = row["location_lat"], let lon: Double = row["location_lon"] {
            location = GeoPoint(latitude: lat, longitude: lon)
        }
        let mediaSubtypes: Int64 = row["media_subtypes"]
        return AssetRecord(
            assetKey: try row.assetKey("asset_key", table: table),
            localId: try row.require("local_id", table: table),
            cloudId: row["cloud_id"],
            creationDate: row["creation_date"],
            modificationDate: row["modification_date"],
            mediaType: try row.parse("media_type", table: table) { (raw: Int) in MediaType(rawValue: raw) },
            mediaSubtypes: MediaSubtypes(rawValue: UInt(truncatingIfNeeded: mediaSubtypes)),
            category: try row.optionalEnum("category", table: table),
            categoryReason: try row.optionalEnum("category_reason", table: table),
            categoryProvisional: row["category_provisional"],
            placement: placement,
            placedAt: row["placed_at"],
            isHidden: row["is_hidden"],
            isFavorite: row["is_favorite"],
            burstIdentifier: row["burst_identifier"],
            burstIsPick: row["burst_is_pick"],
            location: location,
            geoCell: try row.optionalParse("geo_cell", table: table) { (raw: String) in GeoCell(key: raw) },
            pixelWidth: row["pixel_width"],
            pixelHeight: row["pixel_height"],
            duration: row["duration"],
            cameraMake: row["camera_make"],
            cameraModel: row["camera_model"],
            lensModel: row["lens_model"],
            hasAdjustments: row["has_adjustments"],
            adjustmentHash: row["adjustment_hash"],
            editCheckPending: row["edit_check_pending"],
            insertedAt: row["inserted_at"],
            firstSeenAt: try row.require("first_seen_at", table: table),
            lastSeenAt: try row.require("last_seen_at", table: table),
            deletedAt: row["deleted_at"])
    }
}
