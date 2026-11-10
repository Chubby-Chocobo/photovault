import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// A local destination recovered alone can only guess which folder of a split day is the main one.
/// Those days are marked provisional. When a destination with app properties (Drive) is recovered
/// later, its `pvLogical` paths are the truth: the database is rebound to them, and nothing is moved
/// at Drive.
enum ProvisionalSlots {
    private static let prefix = "slots_provisional:"

    static func days(_ db: Database) throws -> Set<ArchiveDay> {
        Set(try String.fetchAll(db, sql: "SELECT key FROM kv WHERE key LIKE ?", arguments: [prefix + "%"])
            .compactMap { ArchiveDay(string: String($0.dropFirst(prefix.count))) })
    }

    static func mark(_ db: Database, _ days: Set<ArchiveDay>) throws {
        for day in days { try KeyValueRepository.set(db, prefix + day.description, 1) }
    }

    /// Forgets every provisional day: their slots belong to a timezone or database that is gone.
    static func clear(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM kv WHERE key LIKE ?", arguments: [prefix + "%"])
    }

    /// Rebinds the slots of each provisional day to the folders `truth` lists. A Drive folder takes the slot
    /// that holds most of its matched assets (`files`: the asset and the Drive folder its file sits in), and
    /// the display name decides what that leaves. Folders, jobs, asset slots and the main/extra folder data
    /// follow. A day without a Drive folder stays provisional, and so does a day that cannot be rebound
    /// safely; the number of those is returned.
    @discardableResult
    static func resolve(_ db: Database, truth: [RemoteFolderEntry], days: Set<ArchiveDay>, files: [(asset: AssetKey, folder: String)]) throws -> Resolution {
        var result = Resolution()
        for day in days.sorted() {
            let folders = truth.filter { $0.day == day }.sorted { $0.logicalPath < $1.logicalPath }
            guard !folders.isEmpty else { continue }
            let inDay = files.filter { file in folders.contains { $0.logicalPath == file.folder } }
            guard try rebind(db, day: day, truth: folders, files: inDay) else {
                result.skipped += 1
                continue
            }
            try KeyValueRepository.set(db, prefix + day.description, nil)
            result.resolved.append(day)
        }
        return result
    }

    struct Resolution {
        var resolved: [ArchiveDay] = []
        var skipped = 0
    }

    /// A folder at Drive may carry another name than the one its slot now has (it was renamed there only):
    /// the folder is renamed, its files stay.
    static func renameDriftedFolders(_ db: Database, destinationId: DestinationID, days: [ArchiveDay], now: Date) throws {
        for day in days {
            var names: [String: String?] = [:]
            if let stat = try DayStatRepository.fetch(db, day: day) { names["camera/\(day)"] = .some(stat.placeName) }
            for row in try DayPlaceRepository.fetchAll(db, day: day) { names[DynamicLayout.slotLogicalPath(day: day, slot: row.slot)] = .some(row.placeName) }
            for (path, name) in names.sorted(by: { $0.key < $1.key }) {
                let expected = DynamicLayout.dayFolderName(day, placeName: name)
                try MoveJobPlanner.enqueueRename(db, destinationId: destinationId, logicalPath: path, to: expected, now: now)
            }
        }
    }

    private struct Data { var key: String?; var name: String?; var state: PlaceState }

    private static func rebind(_ db: Database, day: ArchiveDay, truth: [RemoteFolderEntry], files: [(asset: AssetKey, folder: String)]) throws -> Bool {
        func ck(_ name: String?) -> String { NameSanitizer.collisionKey(DynamicLayout.dayFolderName(day, placeName: name)) }
        let main = "camera/\(day)"
        var current: [String: Data] = [:]
        if let stat = try DayStatRepository.fetch(db, day: day) {
            current[main] = Data(key: stat.placeKey, name: stat.placeName, state: stat.placeState)
        }
        for row in try DayPlaceRepository.fetchAll(db, day: day) {
            current[DynamicLayout.slotLogicalPath(day: day, slot: row.slot)] = Data(key: row.placeKey, name: row.placeName, state: row.placeName == nil ? .unnamed : .named)
        }

        var mapping: [String: String] = [:]
        var placed = Set<String>()
        // By membership: the pairs (Drive folder, current slot) that share the most assets.
        let held = try heldPaths(db, day: day)
        var shared: [[String]: Int] = [:]
        for file in files {
            for path in held[file.asset.rawValue] ?? [] where current[path] != nil { shared[[file.folder, path], default: 0] += 1 }
        }
        for (pair, _) in shared.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key.lexicographicallyPrecedes($1.key) })
        where mapping[pair[1]] == nil && !placed.contains(pair[0]) {
            mapping[pair[1]] = pair[0]
            placed.insert(pair[0])
        }
        // By name, for what holds no matched file.
        for folder in truth where !placed.contains(folder.logicalPath) {
            if let source = current.keys.sorted().first(where: { mapping[$0] == nil && ck(current[$0]?.name) == NameSanitizer.collisionKey(folder.displayName) }) {
                mapping[source] = folder.logicalPath
                placed.insert(folder.logicalPath)
            }
        }
        let targets = Set(mapping.values)
        for path in current.keys.sorted() where mapping[path] == nil {
            if targets.contains(path) {
                var digits = 12
                var fresh: String
                repeat {
                    fresh = DynamicLayout.slotLogicalPath(day: day, slot: DaySlotPolicy.slug(forRecoveredName: current[path]?.name ?? path, digits: digits))
                    digits += 4
                } while current[fresh] != nil || targets.contains(fresh)
                mapping[path] = fresh
            } else {
                mapping[path] = path
            }
        }
        let moved = mapping.filter { $0.key != $0.value }
        guard !moved.isEmpty else { return true }
        // A row on a target path that no rebound path comes from would break the primary key.
        for target in moved.values where moved[target] == nil {
            if try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM remote_folder WHERE logical_path = ?)", arguments: [target]) == true { return false }
        }

        // Two phases, so a swap of two paths never meets itself.
        for (old, _) in moved {
            try db.execute(sql: "UPDATE remote_folder SET logical_path = ? WHERE logical_path = ?", arguments: ["tmp:" + old, old])
            try db.execute(sql: "UPDATE upload_job SET remote_logical_parent = ? WHERE remote_logical_parent = ?", arguments: ["tmp:" + old, old])
            try remapMoves(db, from: old, to: "tmp:" + old)
        }
        for (old, new) in moved {
            try db.execute(sql: "UPDATE remote_folder SET logical_path = ? WHERE logical_path = ?", arguments: [new, "tmp:" + old])
            try db.execute(sql: "UPDATE upload_job SET remote_logical_parent = ? WHERE remote_logical_parent = ?", arguments: [new, "tmp:" + old])
            try remapMoves(db, from: "tmp:" + old, to: new)
        }
        let slotOf: (String) -> String? = { DynamicLayout.parseCameraDay($0)?.slot }
        for row in try Row.fetchAll(db, sql: "SELECT asset_key, place_slot FROM asset WHERE placement_day = ? AND placement_category = 'camera'", arguments: [day.description]) {
            let oldPath = (row["place_slot"] as String?).map { DynamicLayout.slotLogicalPath(day: day, slot: $0) } ?? main
            guard let new = mapping[oldPath], new != oldPath, let key = AssetKey(rawValue: row["asset_key"]) else { continue }
            try AssetPlacementRepository.setPlaceSlot(db, key: key, slot: slotOf(new))
        }

        var next: [String: Data] = [:]
        for (path, data) in current { next[mapping[path] ?? path] = data }
        if let data = next[main] {
            try DayStatRepository.setPlace(db, day: day, state: data.state, key: data.key, name: data.name)
        } else {
            try DayStatRepository.setPlace(db, day: day, state: .unnamed, key: nil, name: nil)
        }
        try db.execute(sql: "DELETE FROM day_place WHERE day = ?", arguments: [day.description])
        for (path, data) in next where path != main {
            guard let slot = slotOf(path) else { continue }
            try DayPlaceRepository.save(db, DayPlace(day: day, slot: slot, placeKey: data.key, placeName: data.name))
        }
        return true
    }

    /// Open renames follow the folder they were queued for; open moves follow the paths they run between.
    private static func remapMoves(_ db: Database, from old: String, to new: String) throws {
        let open = "state IN ('pending', 'inProgress')"
        try db.execute(sql: "UPDATE move_job SET subject = ? WHERE op = 'renameFolder' AND subject = ? AND \(open)", arguments: [new, old])
        try db.execute(sql: "UPDATE move_job SET from_value = ? WHERE op = 'moveFile' AND from_value = ? AND \(open)", arguments: [new, old])
        try db.execute(sql: "UPDATE move_job SET to_value = ? WHERE op = 'moveFile' AND to_value = ? AND \(open)", arguments: [new, old])
    }

    /// The slot paths of the day where each asset has a file at some destination now.
    private static func heldPaths(_ db: Database, day: ArchiveDay) throws -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        let main = "camera/\(day)"
        for row in try Row.fetchAll(db, sql: """
            SELECT DISTINCT asset_key, remote_logical_parent FROM upload_job
            WHERE remote_id IS NOT NULL AND (remote_logical_parent = ? OR remote_logical_parent LIKE ?)
            """, arguments: [main, main + "@%"]) {
            result[row["asset_key"], default: []].insert(row["remote_logical_parent"])
        }
        return result
    }
}
