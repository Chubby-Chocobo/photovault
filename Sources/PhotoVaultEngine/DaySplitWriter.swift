import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Persists the folders of one camera day: the main folder's name in `day_stat`, the extra folders
/// in `day_place`, each asset's slot, and the renames and file moves that follow. Runs inside the
/// caller's transaction; every destination effect happens later in `MoveWorker`.
enum DaySplitWriter {
    struct Outcome {
        var changed = false
        /// A group's name is still on disk as another folder's name; evaluate the day again later.
        var needsRetry = false
    }

    static func apply(
        _ db: Database, day: ArchiveDay, groups: [PlaceGroup], unassigned: [String], stat: DayStat, context: PipelineContext
    ) throws -> Outcome {
        var outcome = Outcome()
        let rows = try DayPlaceRepository.fetchAll(db, day: day)
        var slots = [DaySlot(slot: nil, key: stat.placeKey, name: stat.placeName, reservedNames: try reserved(db, day: day, slot: nil))]
        for row in rows {
            slots.append(DaySlot(slot: row.slot, key: row.placeKey, name: row.placeName, reservedNames: try reserved(db, day: day, slot: row.slot)))
        }
        let plan = DaySlotPolicy.assign(day: day, groups: groups, slots: slots)
        outcome.needsRetry = !plan.deferredGroups.isEmpty

        outcome.changed = try writeMain(db, day: day, stat: stat, update: plan.updated.first { $0.slot == nil }, context: context)
        for update in plan.updated {
            guard let slot = update.slot else { continue }
            let previous = rows.first { $0.slot == slot }
            if let previous, previous.placeKey == update.key, previous.placeName == update.name { continue }
            try DayPlaceRepository.save(db, DayPlace(day: day, slot: slot, placeKey: update.key, placeName: update.name))
            outcome.changed = true
            if let previous, previous.placeName != update.name {
                try rename(db, day: day, slot: slot, name: update.name, context: context)
                for index in groups.indices where plan.slotOfGroup[index] == slot {
                    for member in groups[index].members { if let key = AssetKey(rawValue: member) { try DirtyQueue.mark(db, asset: key) } }
                }
            }
        }

        let skipped = Set(unassigned).union(plan.deferredGroups.flatMap { groups[$0].members })
        for assigned in plan.assetSlots where !skipped.contains(assigned.id) {
            guard let key = AssetKey(rawValue: assigned.id), let asset = try AssetRepository.fetch(db, key: key),
                  asset.deletedAt == nil, asset.placeSlot != assigned.slot else { continue }
            try AssetPlacementRepository.setPlaceSlot(db, key: key, slot: assigned.slot)
            try enqueueMoves(db, key: key, context: context)
            outcome.changed = true
        }
        return outcome
    }

    // MARK: Main folder

    private static func writeMain(
        _ db: Database, day: ArchiveDay, stat: DayStat, update: DaySlotUpdate?, context: PipelineContext
    ) throws -> Bool {
        let name = update.map(\.name) ?? stat.placeName
        let key = update.map(\.key) ?? stat.placeKey
        let state = update?.state ?? (name == nil ? .unnamed : .named)
        let renamed = name != stat.placeName
        guard renamed || state != stat.placeState || key != stat.placeKey else { return false }
        try DayStatRepository.setPlace(db, day: day, state: state, key: key, name: name)
        if renamed {
            try rename(db, day: day, slot: nil, name: name, context: context)
            for key in try OrganizationQueries.cameraAssetKeys(db, day: day) { try DirtyQueue.mark(db, asset: key) }
        }
        return true
    }

    /// The folder name changed: rename it at every destination.
    private static func rename(_ db: Database, day: ArchiveDay, slot: String?, name: String?, context: PipelineContext) throws {
        let placement = Placement(category: .camera, day: .day(day), nameStem: "")
        guard let level = context.layout.folderChain(for: placement, placeName: name, slot: slot).last else { return }
        for destination in context.destinations {
            try MoveJobPlanner.enqueueRename(
                db, destinationId: destination.id, logicalPath: level.logicalPath, to: level.displayName, now: context.now)
        }
    }

    /// Names a folder may still carry on disk at some destination: the old names of its open renames, and the
    /// display name of its `remote_folder` rows, which also covers a rename that failed for good.
    /// The destination filter lets SQLite use `move_job_subject(destination_id, subject)`; finished moves are
    /// kept, so that table only grows.
    static let openRenamesSQL = """
        SELECT from_value FROM move_job
        WHERE destination_id IN (SELECT id FROM destination) AND subject = ? AND op = 'renameFolder'
          AND state IN ('pending', 'inProgress')
        """
    /// The destination filter lets SQLite use the primary key `(destination_id, logical_path)`.
    static let folderNamesSQL = """
        SELECT display_name FROM remote_folder
        WHERE destination_id IN (SELECT id FROM destination) AND logical_path = ?
        """

    static func reserved(_ db: Database, day: ArchiveDay, slot: String?) throws -> [String?] {
        let path = slot.map { DynamicLayout.slotLogicalPath(day: day, slot: $0) } ?? "camera/\(day)"
        let folders = try String.fetchAll(db, sql: openRenamesSQL, arguments: [path])
            + String.fetchAll(db, sql: folderNamesSQL, arguments: [path])
        let prefix = day.description + " "
        return folders.compactMap { folder in
            if folder == day.description { return .some(nil) }
            return folder.hasPrefix(prefix) ? .some(String(folder.dropFirst(prefix.count))) : nil
        }
    }

    // MARK: Files

    /// Every file of the asset that is at a destination (sidecars included) follows its slot.
    private static func enqueueMoves(_ db: Database, key: AssetKey, context: PipelineContext) throws {
        guard let asset = try AssetRepository.fetch(db, key: key) else { return }
        let target = LayoutResolver.parentLogical(try LayoutResolver.chain(db, asset: asset, layout: context.layout))
        let rows = try Row.fetchAll(db, sql: """
            SELECT destination_id, res_type, remote_logical_parent FROM upload_job
            WHERE asset_key = ? AND remote_id IS NOT NULL AND remote_logical_parent IS NOT NULL
              AND state NOT IN ('uploading', 'cancelled', 'missingRemote')
            """, arguments: [key.rawValue])
        for row in rows {
            guard let destinationId = DestinationID(rawValue: row["destination_id"]) else { continue }
            let identity = JobIdentity(destinationId: destinationId, assetKey: key, resType: ResourceType(rawValue: row["res_type"]))
            let from: String = row["remote_logical_parent"]
            try MoveJobPlanner.enqueueMove(db, identity: identity, from: from, to: target, now: context.now)
        }
    }
}
