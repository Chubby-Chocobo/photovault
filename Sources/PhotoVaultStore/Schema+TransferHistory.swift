import GRDB

/// Sync history. Additive: a column on `upload_job`, three tables, indexes and a trigger. The trigger writes one
/// `transfer_event` row per outcome of an original-file job in the same statement that changes the job, so the
/// history can neither miss an outcome nor record one that was rolled back, whichever code path wrote the job.
extension Schema {
    private static let runOrigins = "'backfill', 'destinationBackfill'"

    static func createTransferHistory(_ db: Database) throws {
        try db.execute(sql: """
        ALTER TABLE upload_job ADD COLUMN backfill_run_id INTEGER;
        CREATE INDEX upload_job_backfill_run ON upload_job(backfill_run_id, state) WHERE backfill_run_id IS NOT NULL;

        CREATE TABLE backfill_run (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            trigger TEXT NOT NULL,
            destination_id TEXT,
            started_at DATETIME NOT NULL,
            closed_at DATETIME,
            finished_at DATETIME,
            approximate INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX backfill_run_open ON backfill_run(trigger, destination_id) WHERE closed_at IS NULL;

        CREATE TABLE transfer_event (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            at DATETIME NOT NULL,
            job_id INTEGER NOT NULL,
            destination_id TEXT NOT NULL,
            asset_key TEXT NOT NULL,
            res_type INTEGER NOT NULL,
            source_id TEXT NOT NULL,
            origin TEXT NOT NULL,
            run_id INTEGER,
            outcome TEXT NOT NULL,
            bytes INTEGER NOT NULL DEFAULT 0,
            reason TEXT,
            detail TEXT,
            approximate INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX transfer_event_source_at ON transfer_event(source_id, at);
        CREATE INDEX transfer_event_run_at ON transfer_event(run_id, at) WHERE run_id IS NOT NULL;
        CREATE INDEX transfer_event_outcome_at ON transfer_event(outcome, at);
        CREATE INDEX transfer_event_job ON transfer_event(job_id);

        CREATE TABLE integrity_check (
            destination_id TEXT NOT NULL,
            asset_key TEXT NOT NULL,
            res_type INTEGER NOT NULL,
            checked_at DATETIME NOT NULL,
            result TEXT NOT NULL,
            PRIMARY KEY (destination_id, asset_key, res_type)
        ) WITHOUT ROWID;

        CREATE INDEX import_item_state_path ON import_item(source_id, state, rel_path);
        """)
        try seedTransferHistory(db)
        try db.execute(sql: historyTrigger)
    }

    /// Jobs that finished before history was recorded: each `done` original-file job becomes one approximate
    /// `uploaded` row at its last change, and every backfill job joins one approximate `beforeHistory` run.
    /// Rows and runs that already exist are left alone, so running it again changes nothing.
    static func seedTransferHistory(_ db: Database) throws {
        try db.execute(sql: """
        INSERT INTO backfill_run (trigger, started_at, closed_at, finished_at, approximate)
            SELECT 'beforeHistory', MIN(updated_at), MAX(updated_at),
                   CASE WHEN SUM(state IN ('pending', 'uploading')) = 0 THEN MAX(updated_at) END, 1
            FROM upload_job
            WHERE origin IN (\(runOrigins)) AND res_type < 1000 AND state != 'cancelled'
              AND NOT EXISTS (SELECT 1 FROM backfill_run WHERE trigger = 'beforeHistory')
            HAVING COUNT(*) > 0;
        UPDATE upload_job SET backfill_run_id = (SELECT id FROM backfill_run WHERE trigger = 'beforeHistory')
            WHERE origin IN (\(runOrigins)) AND res_type < 1000 AND state != 'cancelled' AND backfill_run_id IS NULL
              AND EXISTS (SELECT 1 FROM backfill_run WHERE trigger = 'beforeHistory');
        INSERT INTO transfer_event (at, job_id, destination_id, asset_key, res_type, source_id, origin, run_id, outcome, bytes, approximate)
            SELECT j.updated_at, j.id, j.destination_id, j.asset_key, j.res_type, COALESCE(a.source_id, 'photos'), j.origin,
                   CASE WHEN j.origin IN (\(runOrigins)) THEN j.backfill_run_id END, 'uploaded', COALESCE(r.size_bytes, 0), 1
            FROM upload_job j
            LEFT JOIN asset a ON a.asset_key = j.asset_key
            LEFT JOIN resource r ON r.asset_key = j.asset_key AND r.res_type = j.res_type
            WHERE j.state = 'done' AND j.res_type < 1000 AND NOT EXISTS (SELECT 1 FROM transfer_event e WHERE e.job_id = j.id)
            ORDER BY j.updated_at, j.id;
        """)
    }

    /// One row per outcome (decision record 0032): an upload that finished (`uploaded` when the destination had no
    /// copy from this job, else `updated`), a give-up (`failed`, not repeated while the same failure repeats), a skip
    /// or a cancel. Sidecars (types 1000 and up) are not files the owner keeps a history of.
    static let historyTrigger = """
    CREATE TRIGGER upload_job_history AFTER UPDATE ON upload_job
    WHEN NEW.res_type < 1000 AND (
        (OLD.state = 'uploading' AND NEW.done_gen > OLD.done_gen)
        OR (NEW.state IS NOT OLD.state AND NEW.state IN ('deferred', 'skipped', 'cancelled')))
    BEGIN
        INSERT INTO transfer_event (at, job_id, destination_id, asset_key, res_type, source_id, origin, run_id, outcome, bytes, reason, detail)
        SELECT NEW.updated_at, NEW.id, NEW.destination_id, NEW.asset_key, NEW.res_type,
               COALESCE((SELECT source_id FROM asset WHERE asset_key = NEW.asset_key), 'photos'),
               OLD.origin,
               CASE WHEN OLD.origin IN (\(runOrigins)) THEN OLD.backfill_run_id END,
               CASE WHEN OLD.state = 'uploading' AND NEW.done_gen > OLD.done_gen
                        THEN CASE WHEN OLD.done_gen = 0 THEN 'uploaded' ELSE 'updated' END
                    WHEN NEW.state = 'deferred' THEN 'failed'
                    ELSE NEW.state END,
               COALESCE((SELECT size_bytes FROM resource WHERE asset_key = NEW.asset_key AND res_type = NEW.res_type), 0),
               CASE WHEN NEW.state IN ('deferred', 'skipped') THEN NEW.state_reason END,
               CASE WHEN NEW.state IN ('deferred', 'skipped') THEN NEW.last_error END
        WHERE NOT (NEW.state = 'deferred' AND EXISTS (
            SELECT 1 FROM transfer_event e
            WHERE e.id = (SELECT MAX(id) FROM transfer_event WHERE job_id = NEW.id)
              AND e.outcome = 'failed' AND e.reason IS NEW.state_reason));
    END;
    """
}
