import GRDB

/// Counters the status snapshot reads instead of scanning `upload_job` (hundreds of thousands of
/// rows). Triggers keep them in step with every insert, update and delete of a job, whichever code
/// path writes it, inside the same transaction.
extension Schema {
    private static let openStates = "'pending', 'uploading', 'deferred', 'missingRemote'"
    private static let backfillOrigins = "'backfill', 'destinationBackfill'"

    /// Ordering of the classify pass: inserted assets first, then newest first. Partial, because
    /// only provisional assets are ever walked.
    static func createProvisionalIndex(_ db: Database) throws {
        try db.execute(sql: """
        CREATE INDEX asset_provisional_order ON asset((inserted_at IS NULL), COALESCE(creation_date, '') DESC, asset_key DESC)
            WHERE category_provisional = 1 AND deleted_at IS NULL;
        """)
    }

    static func createSnapshotCounters(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE job_count (
            destination_id TEXT NOT NULL,
            state TEXT NOT NULL,
            n INTEGER NOT NULL,
            PRIMARY KEY (destination_id, state)
        ) WITHOUT ROWID;
        CREATE TABLE backfill_asset (
            asset_key TEXT PRIMARY KEY NOT NULL,
            total INTEGER NOT NULL,
            open INTEGER NOT NULL
        ) WITHOUT ROWID;
        CREATE INDEX backfill_asset_open ON backfill_asset(asset_key) WHERE open > 0;
        CREATE TABLE job_bytes (job_id INTEGER PRIMARY KEY NOT NULL, bytes INTEGER NOT NULL);
        CREATE TABLE snapshot_counter (name TEXT PRIMARY KEY NOT NULL, value INTEGER NOT NULL) WITHOUT ROWID;

        INSERT INTO job_count (destination_id, state, n)
            SELECT destination_id, state, COUNT(*) FROM upload_job GROUP BY destination_id, state;
        INSERT INTO backfill_asset (asset_key, total, open)
            SELECT asset_key, SUM(state != 'cancelled'), SUM(state IN (\(openStates))) FROM upload_job
            WHERE origin IN (\(backfillOrigins)) GROUP BY asset_key HAVING SUM(state != 'cancelled') > 0;
        INSERT INTO job_bytes (job_id, bytes)
            SELECT j.id, COALESCE(r.size_bytes, 0) FROM upload_job j
            LEFT JOIN resource r ON r.asset_key = j.asset_key AND r.res_type = j.res_type WHERE j.state = 'done';
        INSERT INTO snapshot_counter (name, value) VALUES ('uploaded_bytes', (SELECT COALESCE(SUM(bytes), 0) FROM job_bytes));

        CREATE TRIGGER upload_job_counters_insert AFTER INSERT ON upload_job BEGIN
            \(add("NEW"))
            \(cleanup("NEW"))
        END;
        CREATE TRIGGER upload_job_counters_delete AFTER DELETE ON upload_job BEGIN
            \(remove("OLD"))
            \(cleanup("OLD"))
        END;
        CREATE TRIGGER upload_job_counters_update AFTER UPDATE ON upload_job
        WHEN OLD.state IS NOT NEW.state OR OLD.origin IS NOT NEW.origin OR OLD.destination_id IS NOT NEW.destination_id
            OR OLD.asset_key IS NOT NEW.asset_key OR OLD.res_type IS NOT NEW.res_type
        BEGIN
            \(remove("OLD"))
            \(add("NEW"))
            \(cleanup("NEW"))
            \(cleanup("OLD"))
        END;
        """)
    }

    private static func add(_ row: String) -> String { apply(row, sign: 1) + """

            INSERT OR REPLACE INTO job_bytes (job_id, bytes)
                SELECT \(row).id, COALESCE((SELECT size_bytes FROM resource WHERE asset_key = \(row).asset_key AND res_type = \(row).res_type), 0)
                WHERE \(row).state = 'done';
            UPDATE snapshot_counter SET value = value + COALESCE((SELECT bytes FROM job_bytes WHERE job_id = \(row).id), 0)
                WHERE name = 'uploaded_bytes' AND \(row).state = 'done';
        """
    }

    private static func remove(_ row: String) -> String { apply(row, sign: -1) + """

            UPDATE snapshot_counter SET value = value - COALESCE((SELECT bytes FROM job_bytes WHERE job_id = \(row).id), 0)
                WHERE name = 'uploaded_bytes' AND \(row).state = 'done';
            DELETE FROM job_bytes WHERE job_id = \(row).id AND \(row).state = 'done';
        """
    }

    private static func apply(_ row: String, sign: Int) -> String {
        """
            INSERT INTO job_count (destination_id, state, n) VALUES (\(row).destination_id, \(row).state, \(sign))
                ON CONFLICT(destination_id, state) DO UPDATE SET n = n + \(sign);
            INSERT INTO backfill_asset (asset_key, total, open)
                SELECT \(row).asset_key, \(sign) * (\(row).state != 'cancelled'), \(sign) * (\(row).state IN (\(openStates)))
                WHERE \(row).origin IN (\(backfillOrigins))
                ON CONFLICT(asset_key) DO UPDATE SET total = total + excluded.total, open = open + excluded.open;
        """
    }

    private static func cleanup(_ row: String) -> String {
        "DELETE FROM backfill_asset WHERE asset_key = \(row).asset_key AND total = 0 AND open = 0;"
    }
}
