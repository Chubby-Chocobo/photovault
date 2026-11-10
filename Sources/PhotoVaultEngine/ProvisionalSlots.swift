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

    /// Rebinds the slots of each provisional day to the folders `truth` lists, matching by display name.
    /// Folders, jobs, asset slots and the main/extra folder data follow; a day without a Drive folder stays provisional.
    static func resolve(_ db: Database, truth: [RemoteFolderEntry], days: Set<ArchiveDay>) throws {
        for day in days.sorted() {
            let folders = truth.filter { $0.day == day }.sorted { $0.logicalPath < $1.logicalPath }
            guard !folders.isEmpty else { continue }
            try rebind(db, day: day, truth: folders)
            try KeyValueRepository.set(db, prefix + day.description, nil)
        }
    }

    private struct Data { var key: String?; var name: String?; var state: PlaceState }

    private static func rebind(_ db: Database, day: ArchiveDay, truth: [RemoteFolderEntry]) throws {
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
        for folder in truth {
            if let source = current.keys.sorted().first(where: { mapping[$0] == nil && ck(current[$0]?.name) == NameSanitizer.collisionKey(folder.displayName) }) {
                mapping[source] = folder.logicalPath
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
        guard !moved.isEmpty else { return }

        // Two phases, so a swap of two paths never meets itself.
        for (old, _) in moved {
            try db.execute(sql: "UPDATE remote_folder SET logical_path = ? WHERE logical_path = ?", arguments: ["tmp:" + old, old])
            try db.execute(sql: "UPDATE upload_job SET remote_logical_parent = ? WHERE remote_logical_parent = ?", arguments: ["tmp:" + old, old])
        }
        for (old, new) in moved {
            try db.execute(sql: "UPDATE remote_folder SET logical_path = ? WHERE logical_path = ?", arguments: [new, "tmp:" + old])
            try db.execute(sql: "UPDATE upload_job SET remote_logical_parent = ? WHERE remote_logical_parent = ?", arguments: [new, "tmp:" + old])
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
    }
}
