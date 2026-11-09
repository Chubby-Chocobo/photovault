import GRDB
import PhotoVaultCore

/// Reads the counters the schema keeps for the status snapshot. Each read touches a few small
/// rows, however many jobs exist.
public enum SnapshotCounterRepository {
    /// Job count per destination and state (states with no job are absent).
    public static func jobCounts(_ db: Database) throws -> [DestinationID: [JobState: Int]] {
        var result: [DestinationID: [JobState: Int]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT destination_id, state, n FROM job_count WHERE n > 0") {
            guard let destination = DestinationID(rawValue: row["destination_id"]), let state = JobState(rawValue: row["state"]) else { continue }
            result[destination, default: [:]][state] = row["n"] as Int
        }
        return result
    }

    /// (assets with backfill jobs, of which finished).
    public static func backfillProgress(_ db: Database) throws -> (done: Int, total: Int) {
        let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM backfill_asset") ?? 0
        let open = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM backfill_asset WHERE open > 0") ?? 0
        return (total - open, total)
    }

    /// Size of the resources behind `done` jobs, counted when each job became `done`.
    public static func uploadedBytes(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT value FROM snapshot_counter WHERE name = 'uploaded_bytes'") ?? 0
    }
}
