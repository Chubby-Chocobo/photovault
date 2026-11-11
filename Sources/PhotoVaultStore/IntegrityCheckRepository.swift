import Foundation
import GRDB
import PhotoVaultCore

/// `integrity_check`: the latest integrity result of each file at each destination.
public enum IntegrityCheckRepository {
    public static func record(
        _ db: Database, identity: JobIdentity, result: IntegrityCheckResult, at date: Date
    ) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO integrity_check (destination_id, asset_key, res_type, checked_at, result) VALUES (?, ?, ?, ?, ?)
            """, arguments: [identity.destinationId.rawValue, identity.assetKey.rawValue, identity.resType.rawValue, date, result.rawValue])
    }

    public static func fetch(_ db: Database, identity: JobIdentity) throws -> (at: Date, result: IntegrityCheckResult)? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT checked_at, result FROM integrity_check WHERE destination_id = ? AND asset_key = ? AND res_type = ?
            """, arguments: [identity.destinationId.rawValue, identity.assetKey.rawValue, identity.resType.rawValue]) else { return nil }
        let table = "integrity_check"
        return (try row.require("checked_at", table: table), try row.enumValue("result", table: table))
    }
}
