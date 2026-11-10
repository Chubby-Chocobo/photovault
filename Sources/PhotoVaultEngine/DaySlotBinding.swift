import Foundation
import PhotoVaultCore

/// Decides which logical day folder each listed camera day folder of a destination is, before
/// anything is written. A listing alone cannot say which folder of a split day is the main one on a
/// local destination, so the database is asked first: by folder id, then by display name, and only
/// then by the assets its files hold, and only then by what the listing itself says. Every folder of a
/// destination is bound by id and name before any folder falls back. Pure.
enum DaySlotBinding {
    /// - Parameters:
    ///   - known: the main folder (from `day_stat`) and extra folders (from `day_place`) of each day.
    ///   - rows: this destination's `remote_folder` rows.
    /// - Returns: the inventory with every camera day folder and its files on a logical path, and the
    ///   number of folders skipped because their path was already bound to another folder.
    static func bind(
        _ inventory: RemoteInventory, known: [ArchiveDay: [DaySlot]], rows: [RemoteFolder], isDrive: Bool,
        provisionalDays: Set<ArchiveDay> = [], slotPathOfAsset: [String: String] = [:]
    ) -> (inventory: RemoteInventory, conflicts: Int, guessed: Set<ArchiveDay>, byContents: Set<ArchiveDay>) {
        let listed = Set(inventory.folders.map(\.remoteId))
        let rowByRemoteId = Dictionary(grouping: rows.filter { $0.remoteId != nil }, by: { $0.remoteId! })
            .mapValues { $0.map(\.logicalPath).sorted().first! }
        let rowByPath = Dictionary(rows.map { ($0.logicalPath, $0) }, uniquingKeysWith: { first, _ in first })

        var result = inventory
        var reassigned: [String: String] = [:]
        var dropped = Set<String>()
        var bound: [String: String] = [:]
        var conflicts = 0
        var guessed = Set<ArchiveDay>()
        var byContents = Set<ArchiveDay>()

        /// A row holds `path` for a different folder that is still listed.
        func held(_ path: String, by folder: RemoteFolderEntry) -> Bool {
            guard let row = rowByPath[path], let id = row.remoteId else { return false }
            return id != folder.remoteId && listed.contains(id)
        }
        func free(_ path: String, for folder: RemoteFolderEntry) -> Bool { bound[path] == nil && !held(path, by: folder) }

        let dayFolders = inventory.folders.filter { $0.day != nil }.sorted {
            (ck($0.displayName), $0.remoteId) < (ck($1.displayName), $1.remoteId)
        }
        /// By folder id, then by display name; nil when neither says anything.
        func bindKnown(_ folder: RemoteFolderEntry, day: ArchiveDay, slots: [DaySlot]) -> (path: String?, dropped: Bool) {
            if let rowPath = rowByRemoteId[folder.remoteId], let parsed = DynamicLayout.parseCameraDay(rowPath), parsed.day == day,
               bound[rowPath] == nil {
                return (rowPath, false)
            }
            guard !(isDrive && provisionalDays.contains(day)),
                  let match = slots.first(where: { names(of: $0, day: day).contains(ck(folder.displayName)) }) else { return (nil, false) }
            let candidate = slotPath(match, day: day)
            if bound[candidate] != nil { return (nil, true) }
            return (held(candidate, by: folder) ? nil : candidate, false)
        }
        func commit(_ folder: RemoteFolderEntry, _ path: String) {
            bound[path] = folder.remoteId
            reassigned[folder.remoteId] = path
        }

        var unknown: [RemoteFolderEntry] = []
        for folder in dayFolders {
            guard let day = folder.day else { continue }
            let found = bindKnown(folder, day: day, slots: known[day] ?? [])
            if found.dropped {
                conflicts += 1
                dropped.insert(folder.remoteId)
            } else if let path = found.path {
                commit(folder, path)
            } else {
                unknown.append(folder)
            }
        }
        for folder in unknown {
            guard let day = folder.day else { continue }
            let slots = known[day] ?? []
            let owned = Set(slots.filter { $0.slot != nil || $0.key != nil || $0.name != nil || !$0.reservedNames.isEmpty }.map { slotPath($0, day: day) })
            // By what its files hold: the known slot that most of its assets sit in.
            var counts: [String: Int] = [:]
            for file in inventory.files where file.parentFolderId == folder.remoteId {
                if let key = file.claimedKey, let path = slotPathOfAsset[key], owned.contains(path) { counts[path, default: 0] += 1 }
            }
            if !isDrive, let best = counts.filter({ free($0.key, for: folder) }).max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) {
                commit(folder, best.key)
                byContents.insert(day)
                continue
            }
            // A local listing cannot say which folder is the main one: this binding is a guess, and it never
            // takes the path of a slot the database knows.
            if !isDrive { guessed.insert(day) }
            let preferred = isDrive ? folder.logicalPath : "camera/\(day)"
            if free(preferred, for: folder), isDrive || !owned.contains(preferred) {
                commit(folder, preferred)
            } else {
                var digits = 12
                var candidate: String
                repeat {
                    candidate = DynamicLayout.slotLogicalPath(day: day, slot: DaySlotPolicy.slug(forRecoveredName: folder.displayName, digits: digits))
                    digits += 4
                } while !free(candidate, for: folder) || owned.contains(candidate)
                commit(folder, candidate)
            }
        }

        result.folders = inventory.folders.compactMap { folder in
            if dropped.contains(folder.remoteId) { return nil }
            guard let path = reassigned[folder.remoteId] else { return folder }
            var bound = folder
            bound.logicalPath = path
            bound.slot = DynamicLayout.parseCameraDay(path)?.slot
            return bound
        }
        // The files of a skipped folder are not recovered at all: they stay where they are and their asset is
        // uploaded again into the folder that holds the path.
        result.files = inventory.files.compactMap { file in
            guard let parent = file.parentFolderId else { return file }
            if dropped.contains(parent) { return nil }
            guard let path = reassigned[parent] else { return file }
            var moved = file
            moved.parentLogical = path
            return moved
        }
        return (result, conflicts, guessed, byContents)
    }

    private static func slotPath(_ slot: DaySlot, day: ArchiveDay) -> String {
        slot.slot.map { DynamicLayout.slotLogicalPath(day: day, slot: $0) } ?? "camera/\(day)"
    }

    private static func ck(_ name: String) -> String { NameSanitizer.collisionKey(name) }

    /// The collision keys of the folder names a slot has or may still have on disk.
    private static func names(of slot: DaySlot, day: ArchiveDay) -> Set<String> {
        Set(([slot.name] + slot.reservedNames).map { ck(DynamicLayout.dayFolderName(day, placeName: $0)) })
    }
}
