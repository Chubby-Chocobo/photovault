import Foundation
import GRDB
import PhotoVaultCore

/// `shortcut` rows for Drive views.
public enum ShortcutRepository {
    public static func fetch(_ db: Database, destinationId: DestinationID, view: ViewKind, assetKey: AssetKey) throws -> ShortcutRecord? {
        try Row.fetchOne(
            db, sql: "SELECT * FROM shortcut WHERE destination_id = ? AND view = ? AND asset_key = ?",
            arguments: [destinationId.rawValue, view.rawValue, assetKey.rawValue]).map(decode)
    }

    public static func fetch(_ db: Database, destinationId: DestinationID, state: ShortcutState) throws -> [ShortcutRecord] {
        try Row.fetchAll(
            db, sql: "SELECT * FROM shortcut WHERE destination_id = ? AND state = ? ORDER BY view, asset_key",
            arguments: [destinationId.rawValue, state.rawValue]).map(decode)
    }

    public static func save(_ db: Database, _ s: ShortcutRecord) throws {
        try db.execute(sql: """
            INSERT INTO shortcut (destination_id, view, asset_key, target_id, shortcut_id, parent_logical, state, attempts)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(destination_id, view, asset_key) DO UPDATE SET
                target_id = excluded.target_id, shortcut_id = excluded.shortcut_id,
                parent_logical = excluded.parent_logical, state = excluded.state, attempts = excluded.attempts
            """, arguments: [
                s.destinationId.rawValue, s.view.rawValue, s.assetKey.rawValue, s.targetId, s.shortcutId,
                s.parentLogical, s.state.rawValue, s.attempts,
            ])
    }

    static func decode(_ row: Row) throws -> ShortcutRecord {
        let table = "shortcut"
        return ShortcutRecord(
            destinationId: try row.destinationId("destination_id", table: table),
            view: try row.enumValue("view", table: table),
            assetKey: try row.assetKey("asset_key", table: table),
            targetId: row["target_id"],
            shortcutId: row["shortcut_id"],
            parentLogical: row["parent_logical"],
            state: try row.enumValue("state", table: table),
            attempts: row["attempts"])
    }
}

/// `device_group`, `device_model` and `view_folder_group`.
public enum DeviceGroupRepository {
    /// Maps a normalized `make|model` key to a group, creating the group (with `displayName`) only
    /// when it does not exist, so owner renames survive. Returns the group.
    @discardableResult
    public static func assign(
        _ db: Database, makeModelKey: String, groupId: String, defaultDisplayName: String
    ) throws -> DeviceGroup {
        try db.execute(
            sql: "INSERT OR IGNORE INTO device_group (group_id, display_name) VALUES (?, ?)",
            arguments: [groupId, defaultDisplayName])
        try db.execute(
            sql: "INSERT OR REPLACE INTO device_model (make_model_key, group_id) VALUES (?, ?)",
            arguments: [makeModelKey, groupId])
        guard let group = try group(db, id: groupId) else { throw StoreError.notFound("device_group \(groupId)") }
        return group
    }

    public static func group(_ db: Database, id: String) throws -> DeviceGroup? {
        try Row.fetchOne(db, sql: "SELECT * FROM device_group WHERE group_id = ?", arguments: [id])
            .map { DeviceGroup(groupId: $0["group_id"], displayName: $0["display_name"]) }
    }

    public static func group(_ db: Database, forMakeModelKey key: String) throws -> DeviceGroup? {
        try Row.fetchOne(db, sql: """
            SELECT g.* FROM device_group g JOIN device_model m ON m.group_id = g.group_id WHERE m.make_model_key = ?
            """, arguments: [key]).map { DeviceGroup(groupId: $0["group_id"], displayName: $0["display_name"]) }
    }

    public static func renameGroup(_ db: Database, id: String, displayName: String) throws {
        try db.execute(sql: "UPDATE device_group SET display_name = ? WHERE group_id = ?", arguments: [displayName, id])
    }

    public static func models(_ db: Database, groupId: String) throws -> [DeviceModel] {
        try Row.fetchAll(
            db, sql: "SELECT * FROM device_model WHERE group_id = ? ORDER BY make_model_key", arguments: [groupId]
        ).map { DeviceModel(makeModelKey: $0["make_model_key"], groupId: $0["group_id"]) }
    }

    public static func setViewFolderGroup(_ db: Database, _ group: ViewFolderGroup) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO view_folder_group (view, group_key, display_name) VALUES (?, ?, ?)",
            arguments: [group.view.rawValue, group.groupKey, group.displayName])
    }

    public static func viewFolderGroup(_ db: Database, view: ViewKind, groupKey: String) throws -> ViewFolderGroup? {
        try Row.fetchOne(
            db, sql: "SELECT * FROM view_folder_group WHERE view = ? AND group_key = ?",
            arguments: [view.rawValue, groupKey]
        ).map { ViewFolderGroup(view: view, groupKey: groupKey, displayName: $0["display_name"]) }
    }
}
