import Foundation
import PhotoVaultCore

/// Decides which logical day folder each listed camera day folder of a destination is, before
/// anything is written. A listing alone cannot say which folder of a split day is the main one on a
/// local destination, so the database is asked first: by folder id, then by display name, and only
/// then by what the listing itself says. Pure.
enum DaySlotBinding {
    /// - Parameters:
    ///   - known: the main folder (from `day_stat`) and extra folders (from `day_place`) of each day.
    ///   - rows: this destination's `remote_folder` rows.
    /// - Returns: the inventory with every camera day folder and its files on a logical path, and the
    ///   number of folders skipped because their path was already bound to another folder.
    static func bind(
        _ inventory: RemoteInventory, known: [ArchiveDay: [DaySlot]], rows: [RemoteFolder], isDrive: Bool
    ) -> (inventory: RemoteInventory, conflicts: Int) {
        let listed = Set(inventory.folders.map(\.remoteId))
        let rowByRemoteId = Dictionary(grouping: rows.filter { $0.remoteId != nil }, by: { $0.remoteId! })
            .mapValues { $0.map(\.logicalPath).sorted().first! }
        let rowByPath = Dictionary(rows.map { ($0.logicalPath, $0) }, uniquingKeysWith: { first, _ in first })

        var result = inventory
        var reassigned: [String: String] = [:]
        var dropped = Set<String>()
        var bound: [String: String] = [:]
        var conflicts = 0

        /// A row holds `path` for a different folder that is still listed.
        func held(_ path: String, by folder: RemoteFolderEntry) -> Bool {
            guard let row = rowByPath[path], let id = row.remoteId else { return false }
            return id != folder.remoteId && listed.contains(id)
        }
        func free(_ path: String, for folder: RemoteFolderEntry) -> Bool { bound[path] == nil && !held(path, by: folder) }

        let dayFolders = inventory.folders.filter { $0.day != nil }.sorted {
            (ck($0.displayName), $0.remoteId) < (ck($1.displayName), $1.remoteId)
        }
        for folder in dayFolders {
            guard let day = folder.day else { continue }
            let slots = known[day] ?? []
            var path: String?

            if let rowPath = rowByRemoteId[folder.remoteId], let parsed = DynamicLayout.parseCameraDay(rowPath), parsed.day == day,
               bound[rowPath] == nil {
                path = rowPath
            } else if let match = slots.first(where: { names(of: $0, day: day).contains(ck(folder.displayName)) }) {
                let candidate = match.slot.map { DynamicLayout.slotLogicalPath(day: day, slot: $0) } ?? "camera/\(day)"
                if bound[candidate] != nil {
                    conflicts += 1
                    dropped.insert(folder.remoteId)
                    continue
                }
                if !held(candidate, by: folder) { path = candidate }
            }
            if path == nil {
                let preferred = isDrive ? folder.logicalPath : "camera/\(day)"
                if free(preferred, for: folder) {
                    path = preferred
                } else {
                    var digits = 12
                    var candidate: String
                    repeat {
                        candidate = DynamicLayout.slotLogicalPath(day: day, slot: DaySlotPolicy.slug(forRecoveredName: folder.displayName, digits: digits))
                        digits += 4
                    } while !free(candidate, for: folder) || slots.contains { $0.slot.map { DynamicLayout.slotLogicalPath(day: day, slot: $0) } == candidate }
                    path = candidate
                }
            }
            guard let path else { continue }
            bound[path] = folder.remoteId
            reassigned[folder.remoteId] = path
        }

        result.folders = inventory.folders.compactMap { folder in
            if dropped.contains(folder.remoteId) { return nil }
            guard let path = reassigned[folder.remoteId] else { return folder }
            var bound = folder
            bound.logicalPath = path
            bound.slot = DynamicLayout.parseCameraDay(path)?.slot
            return bound
        }
        result.files = inventory.files.map { file in
            guard let parent = file.parentFolderId else { return file }
            var moved = file
            if dropped.contains(parent) {
                moved.parentLogical = nil
            } else if let path = reassigned[parent] {
                moved.parentLogical = path
            }
            return moved
        }
        return (result, conflicts)
    }

    private static func ck(_ name: String) -> String { NameSanitizer.collisionKey(name) }

    /// The collision keys of the folder names a slot has or may still have on disk.
    private static func names(of slot: DaySlot, day: ArchiveDay) -> Set<String> {
        Set(([slot.name] + slot.reservedNames).map { ck(DynamicLayout.dayFolderName(day, placeName: $0)) })
    }
}
