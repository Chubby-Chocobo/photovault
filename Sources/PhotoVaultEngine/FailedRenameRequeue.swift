import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

extension MoveJobPlanner {
    enum FailedRenameOutcome: Equatable {
        /// Nothing to do: not a day folder, already named right, or another open rename starts from the name on disk.
        case none
        /// One fresh rename, from the name on disk to the name the day has now.
        case queued
        /// The name the day has now was already tried from this name and failed: the folder keeps its name.
        case kept(name: String)
    }

    /// The name a day folder should carry from the data as it is now; nil for any other folder.
    static func currentDayFolderName(_ db: Database, logicalPath: String) throws -> String? {
        guard let (day, slot) = DynamicLayout.parseCameraDay(logicalPath) else { return nil }
        if let slot {
            guard let row = try DayPlaceRepository.fetchAll(db, day: day).first(where: { $0.slot == slot }) else { return nil }
            return DynamicLayout.dayFolderName(day, placeName: row.placeName)
        }
        guard let stat = try DayStatRepository.fetch(db, day: day) else { return nil }
        return DynamicLayout.dayFolderName(day, placeName: stat.placeName)
    }

    /// A folder rename ended `failed`: the renames queued behind it were written for the name it would have
    /// produced and will be discarded, so the folder would keep its old name until the place changes again.
    /// Queues one rename to the name the day has now, never to the name that just failed, and never a second
    /// time for the same pair of names, so a rename that keeps failing cannot loop. A folder is only ever
    /// renamed (exclusive: an existing folder is never overwritten or merged into).
    static func requeueAfterFailedRename(_ db: Database, failed: MoveJob, now: Date) throws -> FailedRenameOutcome {
        let destination = failed.destinationId.rawValue
        guard let folder = try RemoteFolderRepository.fetch(db, destinationId: failed.destinationId, logicalPath: failed.subject),
              folder.created, let correct = try currentDayFolderName(db, logicalPath: failed.subject),
              NameSanitizer.collisionKey(folder.displayName) != NameSanitizer.collisionKey(correct) else { return .none }
        let startsFromHere = try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM move_job WHERE destination_id = ? AND subject = ? AND op = 'renameFolder'
                           AND state IN ('pending', 'inProgress') AND from_value = ?)
            """, arguments: [destination, failed.subject, folder.displayName]) ?? false
        if startsFromHere { return .none }
        let tried = try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM move_job WHERE destination_id = ? AND subject = ? AND op = 'renameFolder'
                           AND state = 'failed' AND from_value = ? AND to_value = ?)
            """, arguments: [destination, failed.subject, folder.displayName, correct]) ?? false
        if tried { return .kept(name: correct) }
        try MoveJobRepository.insert(db, MoveJob(
            destinationId: failed.destinationId, operation: .renameFolder, subject: failed.subject,
            fromValue: folder.displayName, toValue: correct, createdAt: now))
        return .queued
    }
}
