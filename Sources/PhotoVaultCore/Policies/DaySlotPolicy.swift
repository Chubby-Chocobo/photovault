import CryptoKit
import Foundation

/// A folder of a camera day as the database knows it. `slot == nil` is the main folder (`camera/<day>`).
public struct DaySlot: Hashable, Sendable {
    public var slot: String?
    public var key: String?
    public var name: String?
    /// Names this folder may still carry on disk: the old names of its open renames.
    public var reservedNames: [String?]

    public init(slot: String?, key: String?, name: String?, reservedNames: [String?] = []) {
        self.slot = slot
        self.key = key
        self.name = name
        self.reservedNames = reservedNames
    }
}

/// The key, name and state a used slot ends up with (those of the largest group assigned to it).
public struct DaySlotUpdate: Hashable, Sendable {
    public var slot: String?
    public var key: String?
    public var name: String?
    public var state: PlaceState
}

public struct AssetSlot: Hashable, Sendable {
    public var id: String
    public var slot: String?
}

public struct DaySlotPlan: Hashable, Sendable {
    /// Parallel to the input groups.
    public var slotOfGroup: [String?]
    /// Only slots some group uses; the others are frozen.
    public var updated: [DaySlotUpdate]
    public var assetSlots: [AssetSlot]
    /// Indices of groups whose name is still on disk as another folder's name. They sit in that folder
    /// for now and are placed by name once the rename that vacates it has run.
    public var deferredGroups: [Int]
}

/// Maps the groups of one day onto folders so that no two folders ever share a name, including names
/// that are still on disk while a rename retries. Pure.
///
/// Four passes, each over all groups in input order (largest first): by name, by key, the main
/// folder, a new folder. Every pass starts with the name lookup, which is the only way to keep two
/// folders from ending up with one directory.
public enum DaySlotPolicy {
    private struct Ref: Hashable { var slot: String? }

    public static func assign(day: ArchiveDay, groups: [PlaceGroup], slots: [DaySlot]) -> DaySlotPlan {
        func ck(_ name: String?) -> String { NameSanitizer.collisionKey(DynamicLayout.dayFolderName(day, placeName: name)) }

        let someGroupUnnamed = groups.contains { $0.name == nil }
        var index: [String: Ref] = [:]
        for slot in slots {
            let neverNamed = slot.slot == nil && slot.key == nil && slot.name == nil
            if !neverNamed || someGroupUnnamed { index[ck(slot.name)] = index[ck(slot.name)] ?? Ref(slot: slot.slot) }
            for reserved in slot.reservedNames { index[ck(reserved)] = index[ck(reserved)] ?? Ref(slot: slot.slot) }
        }

        var chosen = [Ref?](repeating: nil, count: groups.count)
        var owner: [Ref: Int] = [:]
        var deferred: [Int] = []
        var existing = Set(slots.compactMap(\.slot))

        func take(_ g: Int, _ ref: Ref) {
            chosen[g] = ref
            if owner[ref] == nil { owner[ref] = g }
            if index[ck(groups[g].name)] == nil { index[ck(groups[g].name)] = ref }
        }
        /// True when the group was placed by name (or deferred because its name belongs to a folder named otherwise).
        func placeByName(_ g: Int) -> Bool {
            guard let ref = index[ck(groups[g].name)] else { return false }
            if let first = owner[ref], ck(groups[first].name) != ck(groups[g].name) {
                chosen[g] = ref
                deferred.append(g)
            } else {
                take(g, ref)
            }
            return true
        }

        for g in groups.indices where chosen[g] == nil { _ = placeByName(g) }
        for g in groups.indices where chosen[g] == nil && !placeByName(g) {
            guard let key = groups[g].key, let match = slots.first(where: { $0.key == key && owner[Ref(slot: $0.slot)] == nil })
            else { continue }
            take(g, Ref(slot: match.slot))
        }
        for g in groups.indices where chosen[g] == nil && !placeByName(g) {
            if owner[Ref(slot: nil)] == nil { take(g, Ref(slot: nil)) }
        }
        for g in groups.indices where chosen[g] == nil && !placeByName(g) {
            var digits = 12
            var slug = slug(forKey: groups[g].key, digits: digits)
            while existing.contains(slug) {
                digits += 4
                slug = Self.slug(forKey: groups[g].key, digits: digits)
            }
            existing.insert(slug)
            take(g, Ref(slot: slug))
        }

        let updated = owner.sorted { $0.value < $1.value }.map { ref, g in
            DaySlotUpdate(slot: ref.slot, key: groups[g].key, name: groups[g].name, state: groups[g].state)
        }
        let assetSlots = groups.indices.flatMap { g in groups[g].members.map { AssetSlot(id: $0, slot: chosen[g]?.slot) } }
        return DaySlotPlan(
            slotOfGroup: chosen.map { $0?.slot }, updated: updated, assetSlots: assetSlots, deferredGroups: deferred.sorted())
    }

    /// `p` + the first `digits` hex digits of SHA-256 of the province key. Survives renames of the folder.
    public static func slug(forKey key: String?, digits: Int = 12) -> String {
        "p" + hex(key ?? "", digits)
    }

    /// `r` + the first `digits` hex digits of SHA-256 of the folder name's collision key; for folders
    /// found on a destination that the database does not know.
    public static func slug(forRecoveredName name: String, digits: Int = 12) -> String {
        "r" + hex(NameSanitizer.collisionKey(name), digits)
    }

    private static func hex(_ text: String, _ digits: Int) -> String {
        String(SHA256.hash(data: Data(text.utf8)).hexString.prefix(digits))
    }
}
