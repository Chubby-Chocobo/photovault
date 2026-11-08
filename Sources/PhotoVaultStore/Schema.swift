import GRDB

/// Database schema. `v1` is final once shipped; later changes are new migrations.
enum Schema {
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1", migrate: createV1)
        return migrator
    }

    /// Referential integrity is enforced by the repositories: assets are soft-deleted and never
    /// removed, and destination removal deletes its dependent rows explicitly.
    private static func createV1(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE destination (
            id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            display_name TEXT NOT NULL,
            status TEXT NOT NULL,
            status_reason TEXT,
            status_since DATETIME NOT NULL,
            scope_mode TEXT NOT NULL,
            scope_since TEXT,
            baseline_at DATETIME,
            rules_json TEXT NOT NULL,
            config_json TEXT NOT NULL,
            account_id TEXT,
            account_email TEXT,
            recovery_required INTEGER NOT NULL DEFAULT 0,
            last_success_at DATETIME,
            created_at DATETIME NOT NULL
        );

        CREATE TABLE asset (
            asset_key TEXT PRIMARY KEY NOT NULL,
            asset_key_hash TEXT NOT NULL,
            local_id TEXT NOT NULL UNIQUE,
            cloud_id TEXT,
            creation_date DATETIME,
            creation_day TEXT,
            modification_date DATETIME,
            media_type INTEGER NOT NULL,
            media_subtypes INTEGER NOT NULL DEFAULT 0,
            category TEXT,
            category_reason TEXT,
            category_provisional INTEGER NOT NULL DEFAULT 0,
            placement_category TEXT,
            placement_day TEXT,
            name_stem TEXT,
            placed_at DATETIME,
            is_hidden INTEGER NOT NULL DEFAULT 0,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            burst_identifier TEXT,
            burst_is_pick INTEGER NOT NULL DEFAULT 1,
            location_lat DOUBLE,
            location_lon DOUBLE,
            geo_cell TEXT,
            pixel_width INTEGER NOT NULL DEFAULT 0,
            pixel_height INTEGER NOT NULL DEFAULT 0,
            duration DOUBLE NOT NULL DEFAULT 0,
            camera_make TEXT,
            camera_model TEXT,
            lens_model TEXT,
            has_adjustments INTEGER NOT NULL DEFAULT 0,
            adjustment_hash TEXT,
            edit_check_pending INTEGER NOT NULL DEFAULT 0,
            inserted_at DATETIME,
            first_seen_at DATETIME NOT NULL,
            last_seen_at DATETIME NOT NULL,
            deleted_at DATETIME
        );
        CREATE INDEX asset_cloud_id ON asset(cloud_id);
        CREATE INDEX asset_placement ON asset(placement_day, category);
        CREATE INDEX asset_key_hash ON asset(asset_key_hash);
        CREATE INDEX asset_creation_day ON asset(creation_day);

        CREATE TABLE asset_alias (
            alias TEXT PRIMARY KEY NOT NULL,
            asset_key TEXT NOT NULL
        );
        CREATE INDEX asset_alias_asset ON asset_alias(asset_key);

        CREATE TABLE name_alloc (
            placement_category TEXT NOT NULL,
            placement_day TEXT NOT NULL,
            norm_stem TEXT NOT NULL,
            asset_key TEXT NOT NULL,
            PRIMARY KEY (placement_category, placement_day, norm_stem)
        );

        CREATE TABLE album_member (
            album_local_id TEXT NOT NULL,
            album_title TEXT NOT NULL,
            asset_key TEXT NOT NULL,
            PRIMARY KEY (album_local_id, asset_key)
        );
        CREATE INDEX album_member_asset ON album_member(asset_key);

        CREATE TABLE resource (
            asset_key TEXT NOT NULL,
            res_type INTEGER NOT NULL,
            kind TEXT NOT NULL,
            is_raw INTEGER NOT NULL DEFAULT 0,
            original_filename TEXT NOT NULL,
            uti TEXT NOT NULL,
            size_bytes INTEGER,
            content_gen INTEGER NOT NULL DEFAULT 1,
            md5 TEXT,
            sha256 TEXT,
            staging_gen INTEGER NOT NULL DEFAULT 0,
            staging_path TEXT,
            staging_state TEXT NOT NULL DEFAULT 'none',
            export_count INTEGER NOT NULL DEFAULT 0,
            export_attempts INTEGER NOT NULL DEFAULT 0,
            export_deferred_since DATETIME,
            next_export_attempt_at DATETIME,
            bytes_received_at_cancel INTEGER,
            disk_cancel_count INTEGER NOT NULL DEFAULT 0,
            too_large_for_disk INTEGER NOT NULL DEFAULT 0,
            last_used_at DATETIME,
            last_error TEXT,
            PRIMARY KEY (asset_key, res_type)
        );
        CREATE INDEX resource_staging ON resource(staging_state);

        CREATE TABLE upload_job (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            destination_id TEXT NOT NULL,
            asset_key TEXT NOT NULL,
            res_type INTEGER NOT NULL,
            kind TEXT NOT NULL,
            origin TEXT NOT NULL,
            state TEXT NOT NULL,
            state_reason TEXT,
            remote_logical_parent TEXT,
            remote_name TEXT,
            remote_id TEXT,
            session_ref TEXT,
            session_md5 TEXT,
            uploaded_hash TEXT,
            target_gen INTEGER NOT NULL DEFAULT 1,
            done_gen INTEGER NOT NULL DEFAULT 0,
            uploading_gen INTEGER,
            mismatch_count INTEGER NOT NULL DEFAULT 0,
            attempts INTEGER NOT NULL DEFAULT 0,
            next_attempt_at DATETIME,
            deferred_since DATETIME,
            last_error TEXT,
            updated_at DATETIME NOT NULL
        );
        CREATE UNIQUE INDEX upload_job_identity ON upload_job(destination_id, asset_key, res_type);
        CREATE INDEX upload_job_state ON upload_job(state, destination_id);
        CREATE INDEX upload_job_asset ON upload_job(asset_key);

        CREATE TABLE day_stat (
            day TEXT PRIMARY KEY NOT NULL,
            count INTEGER NOT NULL DEFAULT 0,
            promoted INTEGER NOT NULL DEFAULT 0,
            promoted_at DATETIME,
            place_key TEXT,
            place_name TEXT,
            place_state TEXT NOT NULL DEFAULT 'pending'
        );

        CREATE TABLE geo_cache (
            geo_cell TEXT NOT NULL,
            locale TEXT NOT NULL,
            iso_country TEXT,
            country TEXT,
            administrative_area TEXT,
            locality TEXT,
            fetched_at DATETIME NOT NULL,
            PRIMARY KEY (geo_cell, locale)
        );

        CREATE TABLE remote_folder (
            destination_id TEXT NOT NULL,
            logical_path TEXT NOT NULL,
            remote_id TEXT,
            display_name TEXT NOT NULL,
            created INTEGER NOT NULL DEFAULT 0,
            verified_session TEXT,
            PRIMARY KEY (destination_id, logical_path)
        );

        CREATE TABLE move_job (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            destination_id TEXT NOT NULL,
            op TEXT NOT NULL,
            subject TEXT NOT NULL,
            from_value TEXT NOT NULL,
            to_value TEXT NOT NULL,
            state TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            created_at DATETIME NOT NULL
        );
        CREATE INDEX move_job_state ON move_job(destination_id, state);

        CREATE TABLE device_group (
            group_id TEXT PRIMARY KEY NOT NULL,
            display_name TEXT NOT NULL
        );
        CREATE TABLE device_model (
            make_model_key TEXT PRIMARY KEY NOT NULL,
            group_id TEXT NOT NULL
        );
        CREATE TABLE view_folder_group (
            view TEXT NOT NULL,
            group_key TEXT NOT NULL,
            display_name TEXT NOT NULL,
            PRIMARY KEY (view, group_key)
        );

        CREATE TABLE shortcut (
            destination_id TEXT NOT NULL,
            view TEXT NOT NULL,
            asset_key TEXT NOT NULL,
            target_id TEXT,
            shortcut_id TEXT,
            parent_logical TEXT,
            state TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (destination_id, view, asset_key)
        );

        CREATE TABLE activity (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            at DATETIME NOT NULL,
            kind TEXT NOT NULL,
            destination_id TEXT,
            asset_key TEXT,
            message TEXT NOT NULL
        );

        CREATE TABLE kv (
            key TEXT PRIMARY KEY NOT NULL,
            value
        );
        """)
    }
}
