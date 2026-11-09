import GRDB

/// Sources and one-time imports. Additive: existing assets read back as `source_id = 'photos'`.
extension Schema {
    static func createSources(_ db: Database) throws {
        try db.execute(sql: """
        ALTER TABLE asset ADD COLUMN source_id TEXT NOT NULL DEFAULT 'photos';
        CREATE INDEX asset_source ON asset(source_id, deleted_at);
        CREATE INDEX resource_sha256 ON resource(sha256);

        CREATE TABLE source (
            id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            mode TEXT NOT NULL,
            display_name TEXT NOT NULL,
            config_json TEXT NOT NULL,
            status TEXT NOT NULL,
            status_reason TEXT,
            created_at DATETIME NOT NULL,
            listed_at DATETIME,
            finished_at DATETIME
        );

        CREATE TABLE import_item (
            source_id TEXT NOT NULL,
            rel_path TEXT NOT NULL,
            group_key TEXT NOT NULL,
            uti TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            created_at_fs DATETIME,
            modified_at_fs DATETIME,
            state TEXT NOT NULL DEFAULT 'pending',
            asset_key TEXT,
            is_primary INTEGER NOT NULL DEFAULT 0,
            date_source TEXT,
            reason TEXT,
            PRIMARY KEY (source_id, rel_path)
        );
        CREATE INDEX import_item_group ON import_item(source_id, state, group_key);
        CREATE INDEX import_item_asset ON import_item(asset_key);
        """)
    }
}
