import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Work that later cycle steps pick up, stored in `kv` so it is written in the same transaction as
/// the change that caused it and survives a restart. `dirty:<channel>:<id>` marks one subject
/// (asset key, or day for `.place`); `sweep:<channel>` holds the cursor of a full pass over the
/// live assets (view toggles, "Dựng lại view", reconciliation).
enum DirtyQueue {
    enum Channel: String, CaseIterable, Sendable {
        case sidecar, view, description, place
    }

    private static func prefix(_ channel: Channel) -> String { "dirty:\(channel.rawValue):" }
    private static func sweepKey(_ channel: Channel) -> String { "sweep:\(channel.rawValue)" }

    static func mark(_ db: Database, _ channels: [Channel], id: String) throws {
        for channel in channels {
            try db.execute(sql: "INSERT OR REPLACE INTO kv (key, value) VALUES (?, 1)", arguments: [prefix(channel) + id])
        }
    }

    static func mark(_ db: Database, _ channels: [Channel] = [.sidecar, .view, .description], asset key: AssetKey) throws {
        try mark(db, channels, id: key.rawValue)
    }

    /// Marks every asset of a geo cell (a geocode arrived) for sidecar, view and description refresh.
    static func markAssets(_ db: Database, inCell cell: GeoCell) throws {
        let keys = try String.fetchAll(db, sql: """
            SELECT asset_key FROM asset WHERE geo_cell = ? AND deleted_at IS NULL
            """, arguments: [cell.key])
        for key in keys { try mark(db, [.sidecar, .view, .description], id: key) }
        let days = try String.fetchAll(db, sql: """
            SELECT DISTINCT a.placement_day FROM asset a JOIN day_stat d ON d.day = a.placement_day
            WHERE a.geo_cell = ? AND d.promoted = 1
            """, arguments: [cell.key])
        for day in days { try mark(db, [.place], id: day) }
    }

    static func pending(_ db: Database, _ channel: Channel, limit: Int) throws -> [String] {
        let head = prefix(channel)
        return try String.fetchAll(db, sql: """
            SELECT substr(key, ?) FROM kv WHERE key LIKE ? ESCAPE '\\' ORDER BY key LIMIT ?
            """, arguments: [head.count + 1, head.replacingOccurrences(of: "_", with: "\\_") + "%", limit])
    }

    static func clear(_ db: Database, _ channel: Channel, ids: [String]) throws {
        for id in ids { try db.execute(sql: "DELETE FROM kv WHERE key = ?", arguments: [prefix(channel) + id]) }
    }

    // MARK: Sweeps

    /// Starts a sweep from the beginning. A sweep that is already running restarts too: what it
    /// processed before the request used the old state.
    static func requestSweep(_ db: Database, _ channels: [Channel]) throws {
        for channel in channels { try KeyValueRepository.set(db, sweepKey(channel), "") }
    }

    /// Cursor of the running sweep, nil when none is requested.
    static func sweepCursor(_ db: Database, _ channel: Channel) throws -> String? {
        try KeyValueRepository.string(db, sweepKey(channel))
    }

    static func setSweepCursor(_ db: Database, _ channel: Channel, _ cursor: String?) throws {
        try KeyValueRepository.set(db, sweepKey(channel), cursor)
    }

    /// The next batch of a sweep: advances the cursor, or ends the sweep when the assets ran out.
    static func nextSweepBatch(_ db: Database, _ channel: Channel, limit: Int) throws -> [AssetKey] {
        guard let cursor = try sweepCursor(db, channel) else { return [] }
        let keys = try EngineQueries.liveAssetKeys(db, after: cursor, limit: limit)
        try setSweepCursor(db, channel, keys.count < limit ? nil : keys.last?.rawValue)
        return keys
    }

    /// Turns the next sweep batch into dirty marks in the caller's transaction, so a crash between
    /// the cursor move and the work loses nothing. Returns how many assets were marked.
    @discardableResult
    static func promoteSweep(_ db: Database, _ channel: Channel, limit: Int = 200) throws -> Int {
        let keys = try nextSweepBatch(db, channel, limit: limit)
        for key in keys { try mark(db, [channel], id: key.rawValue) }
        return keys.count
    }
}
