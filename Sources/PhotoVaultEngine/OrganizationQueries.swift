import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Raw SQL the organization workers need on top of the Store repositories.
enum OrganizationQueries {
    static func hasDoneJob(_ db: Database, key: AssetKey) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT 1 FROM upload_job WHERE asset_key = ? AND state = 'done' LIMIT 1", arguments: [key.rawValue]) != nil
    }

    /// Camera assets placed on `day`, deleted ones included (their files are still in the folder).
    static func cameraAssetKeys(_ db: Database, day: ArchiveDay) throws -> [AssetKey] {
        try String.fetchAll(db, sql: """
            SELECT asset_key FROM asset WHERE placement_category = 'camera' AND placement_day = ? ORDER BY asset_key
            """, arguments: [day.description]).compactMap(AssetKey.init(rawValue:))
    }

    /// Updates only the location columns of a job, so a concurrent state change is never overwritten.
    static func setRemoteLocation(_ db: Database, identity: JobIdentity, parent: String, remoteId: String) throws {
        try db.execute(sql: """
            UPDATE upload_job SET remote_logical_parent = ?, remote_id = ?
            WHERE destination_id = ? AND asset_key = ? AND res_type = ?
            """, arguments: [parent, remoteId, identity.destinationId.rawValue, identity.assetKey.rawValue, identity.resType.rawValue])
    }

    /// Local destinations address files by path: after a folder rename every path below it changes.
    static func rebasePaths(_ db: Database, destinationId: DestinationID, from old: String, to new: String) throws {
        guard old != new, !old.isEmpty else { return }
        try db.execute(sql: """
            UPDATE upload_job SET remote_id = :new || substr(remote_id, length(:old) + 1)
            WHERE destination_id = :destination AND substr(remote_id, 1, length(:old) + 1) = :old || '/'
            """, arguments: ["new": new, "old": old, "destination": destinationId.rawValue])
        try db.execute(sql: """
            UPDATE remote_folder SET remote_id = :new || substr(remote_id, length(:old) + 1)
            WHERE destination_id = :destination AND remote_id IS NOT NULL
              AND substr(remote_id, 1, length(:old) + 1) = :old || '/'
            """, arguments: ["new": new, "old": old, "destination": destinationId.rawValue])
    }

    /// Distinct archive days of promoted camera folders.
    static func promotedDays(_ db: Database) throws -> [ArchiveDay] {
        try String.fetchAll(db, sql: "SELECT day FROM day_stat WHERE promoted = 1 ORDER BY day").compactMap(ArchiveDay.init(string:))
    }
}

/// Decodes `MoveJob.subject(for:)`.
extension JobIdentity {
    init?(subject: String, destinationId: DestinationID) {
        guard let split = subject.lastIndex(of: "|"), let key = AssetKey(rawValue: String(subject[..<split])),
              let raw = Int(subject[subject.index(after: split)...]) else { return nil }
        self.init(destinationId: destinationId, assetKey: key, resType: ResourceType(rawValue: raw))
    }
}

/// Creates `move_job`s without stacking duplicates.
enum MoveJobPlanner {
    /// File `identity` is in `from` but belongs in `to`.
    @discardableResult
    static func enqueueMove(_ db: Database, identity: JobIdentity, from: String, to: String, now: Date) throws -> Bool {
        guard from != to else { return false }
        let subject = MoveJob.subject(for: identity)
        let queued = try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM move_job WHERE destination_id = ? AND subject = ? AND op = 'moveFile'
                           AND to_value = ? AND state IN ('pending', 'inProgress'))
            """, arguments: [identity.destinationId.rawValue, subject, to]) ?? false
        if queued { return false }
        try MoveJobRepository.insert(db, MoveJob(
            destinationId: identity.destinationId, operation: .moveFile, subject: subject, fromValue: from, toValue: to, createdAt: now))
        return true
    }

    /// The folder at `logicalPath` should now be called `name`. Compares with the name the folder
    /// will have once the queued renames ran, so repeated evaluations queue nothing.
    @discardableResult
    static func enqueueRename(_ db: Database, destinationId: DestinationID, logicalPath: String, to name: String, now: Date) throws -> Bool {
        guard let folder = try RemoteFolderRepository.fetch(db, destinationId: destinationId, logicalPath: logicalPath) else { return false }
        let lastQueued = try String.fetchOne(db, sql: """
            SELECT to_value FROM move_job WHERE destination_id = ? AND subject = ? AND op = 'renameFolder'
                AND state IN ('pending', 'inProgress') ORDER BY id DESC LIMIT 1
            """, arguments: [destinationId.rawValue, logicalPath])
        let effective = lastQueued ?? folder.displayName
        guard effective != name else { return false }
        try MoveJobRepository.insert(db, MoveJob(
            destinationId: destinationId, operation: .renameFolder, subject: logicalPath, fromValue: effective, toValue: name, createdAt: now))
        return true
    }
}

extension OrganizationQueries {
    /// `inProgress → pending` without counting a failure (destination-level errors, recovery retries).
    static func requeueMove(_ db: Database, id: Int64) throws {
        try db.execute(sql: "UPDATE move_job SET state = 'pending' WHERE id = ? AND state = 'inProgress'", arguments: [id])
    }

    /// `inProgress → failed`: the job cannot be resolved without an integrity check.
    static func failMove(_ db: Database, id: Int64, message: String) throws {
        try db.execute(sql: "UPDATE move_job SET state = 'failed', last_error = ? WHERE id = ? AND state = 'inProgress'", arguments: [message, id])
    }
}

extension OrganizationQueries {
    /// Changes whenever a sidecar job is created or its target generation is raised.
    static func sidecarVersion(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(target_gen), 0) + COUNT(*) FROM upload_job WHERE res_type IN (1001, 1002)") ?? 0
    }
}
