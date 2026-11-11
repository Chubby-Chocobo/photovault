import Foundation
import GRDB
import PhotoVaultCore

/// `backfill_run`: groups of backfill jobs with one cause. A run is created with its first job, takes new jobs
/// of its cause until it is closed, and is finished while none of its jobs is pending or uploading.
public enum BackfillRunRepository {
    /// A job stays in its run only while it is a backfill job: an edit or a re-upload later is not part of the run.
    static let origins = "'backfill', 'destinationBackfill'"

    /// The open run of `trigger` (for a per-destination cause, of that destination), created when there is none.
    public static func runId(_ db: Database, trigger: BackfillTrigger, destinationId: DestinationID, now: Date) throws -> Int64 {
        let destination = trigger.isPerDestination ? destinationId.rawValue : nil
        if let open = try Int64.fetchOne(db, sql: """
            SELECT id FROM backfill_run WHERE closed_at IS NULL AND trigger = ? AND destination_id IS ? ORDER BY id DESC LIMIT 1
            """, arguments: [trigger.rawValue, destination]) {
            return open
        }
        try db.execute(
            sql: "INSERT INTO backfill_run (trigger, destination_id, started_at) VALUES (?, ?, ?)",
            arguments: [trigger.rawValue, destination, now])
        return db.lastInsertedRowID
    }

    /// An owner command starts a run of its own: the open run of the same cause takes no more jobs.
    public static func close(_ db: Database, trigger: BackfillTrigger, destinationId: DestinationID?, now: Date) throws {
        let destination = trigger.isPerDestination ? destinationId?.rawValue : nil
        try db.execute(sql: """
            UPDATE backfill_run SET closed_at = ? WHERE closed_at IS NULL AND trigger = ? AND destination_id IS ?
            """, arguments: [now, trigger.rawValue, destination])
    }

    /// Runs with no backfill job pending or uploading are finished (at their latest outcome) and closed; a finished run
    /// with such a job again (the 24-hour retry, an owner's retry) is open again until it settles. Failed (deferred)
    /// files do not hold a run open: they are part of its result. A run whose jobs were all deleted (its destination
    /// was removed) finishes too.
    @discardableResult
    public static func finishSettled(_ db: Database, now: Date) throws -> Int {
        let waiting = """
            EXISTS (SELECT 1 FROM upload_job WHERE backfill_run_id = backfill_run.id AND state IN ('pending', 'uploading')
                    AND origin IN (\(origins)))
            """
        try db.execute(sql: "UPDATE backfill_run SET finished_at = NULL WHERE finished_at IS NOT NULL AND \(waiting)")
        try db.execute(sql: """
            UPDATE backfill_run
            SET finished_at = COALESCE((SELECT MAX(at) FROM transfer_event WHERE run_id = backfill_run.id), :now),
                closed_at = COALESCE(closed_at, :now)
            WHERE finished_at IS NULL AND NOT \(waiting)
            """, arguments: ["now": now])
        return db.changesCount
    }

    /// Original-file backfill jobs of a run that failed or were skipped, for "retry all".
    public static func failedJobs(_ db: Database, runId: Int64) throws -> [JobIdentity] {
        try Row.fetchAll(db, sql: """
            SELECT destination_id, asset_key, res_type FROM upload_job
            WHERE backfill_run_id = ? AND state IN ('deferred', 'skipped') AND origin IN (\(origins)) AND res_type < 1000
            ORDER BY id
            """, arguments: [runId]).map { row in
            let table = "upload_job"
            return JobIdentity(
                destinationId: try row.destinationId("destination_id", table: table), assetKey: try row.assetKey("asset_key", table: table),
                resType: ResourceType(rawValue: row["res_type"]))
        }
    }

    /// The runs wait for their jobs again (the owner retried some of them).
    public static func reopen(_ db: Database, runIds: Set<Int64>) throws {
        guard !runIds.isEmpty else { return }
        let marks = runIds.map { _ in "?" }.joined(separator: ", ")
        try db.execute(
            sql: "UPDATE backfill_run SET finished_at = NULL WHERE id IN (\(marks))",
            arguments: StatementArguments(runIds.sorted()))
    }

    /// Newest first, each with the latest outcome of every file and the files still waiting.
    public static func fetchAll(_ db: Database) throws -> [BackfillRunRow] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM backfill_run ORDER BY started_at DESC, id DESC")
        return try rows.map { row in
            let id: Int64 = row["id"]
            let table = "backfill_run"
            let waiting = try waiting(db, runId: id)
            return BackfillRunRow(
                id: id, trigger: try row.enumValue("trigger", table: table),
                destinationId: (row["destination_id"] as String?).flatMap(DestinationID.init(rawValue:)),
                startedAt: try row.require("started_at", table: table), finishedAt: waiting > 0 ? nil : row["finished_at"],
                approximate: row["approximate"], totals: try totals(db, runId: id), waiting: waiting,
                retryable: try failedJobs(db, runId: id).count)
        }
    }

    /// The latest outcome of each file of the run: a file that failed and then uploaded counts as uploaded.
    static let totalsSQL = """
        SELECT e.outcome, COUNT(*) AS files, COALESCE(SUM(e.bytes), 0) AS bytes FROM transfer_event e
        WHERE e.run_id = ?1 AND e.id = (SELECT MAX(id) FROM transfer_event WHERE job_id = e.job_id AND run_id = ?1)
        GROUP BY e.outcome
        """

    static func totals(_ db: Database, runId: Int64) throws -> [TransferOutcome: OutcomeTotal] {
        var result: [TransferOutcome: OutcomeTotal] = [:]
        let rows = try Row.fetchAll(db, sql: totalsSQL, arguments: [runId])
        for row in rows {
            guard let outcome = TransferOutcome(rawValue: row["outcome"]) else { continue }
            result[outcome] = OutcomeTotal(files: row["files"], bytes: row["bytes"])
        }
        return result
    }

    static let waitingSQL = """
        SELECT COUNT(*) FROM upload_job WHERE backfill_run_id = ? AND state IN ('pending', 'uploading') AND origin IN (\(origins))
        """

    static func waiting(_ db: Database, runId: Int64) throws -> Int {
        try Int.fetchOne(db, sql: waitingSQL, arguments: [runId]) ?? 0
    }
}
