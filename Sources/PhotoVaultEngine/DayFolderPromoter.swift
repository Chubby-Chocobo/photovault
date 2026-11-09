import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Day folders (spec 8.7, decision 0023): every camera day has its own folder from its
/// first asset, so the layout never depends on promotion. Promotion now only marks the day for place
/// naming, once and for good.
enum DayFolderPromoter {
    /// Promotes `day` the first time it has a camera asset. The count is not used: it follows the
    /// content filters, and a day of only videos or hidden photos must still be named once the owner
    /// lets them through.
    @discardableResult
    static func promoteIfNeeded(_ db: Database, day: ArchiveDay, context: PipelineContext) throws -> Bool {
        guard let stat = try DayStatRepository.fetch(db, day: day), !stat.promoted,
              try Bool.fetchOne(db, sql: """
                  SELECT EXISTS(SELECT 1 FROM asset WHERE placement_day = ? AND category = 'camera' AND deleted_at IS NULL)
                  """, arguments: [day.description]) == true else { return false }
        return try promote(db, day: day, context: context)
    }

    @discardableResult
    static func promote(_ db: Database, day: ArchiveDay, context: PipelineContext) throws -> Bool {
        guard try DayStatRepository.promote(db, day: day, now: context.now) else { return false }
        try DirtyQueue.mark(db, [.place], id: day.description)
        return true
    }
}
