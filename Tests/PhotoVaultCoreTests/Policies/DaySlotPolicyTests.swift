import Foundation
import Testing
@testable import PhotoVaultCore

@Suite struct DaySlotPolicyTests {
    let day = ArchiveDay(year: 2026, month: 11, day: 8)!

    func main(_ key: String?, _ name: String?, reserved: [String?] = []) -> DaySlot {
        DaySlot(slot: nil, key: key, name: name, reservedNames: reserved)
    }
    func extra(_ slot: String, _ key: String?, _ name: String?, reserved: [String?] = []) -> DaySlot {
        DaySlot(slot: slot, key: key, name: name, reservedNames: reserved)
    }
    func group(_ key: String?, _ name: String?, _ members: [String] = ["a"], state: PlaceState? = nil) -> PlaceGroup {
        PlaceGroup(key: key, name: name, state: state ?? (key == nil ? .unnamed : .named), members: members)
    }
    func plan(_ slots: [DaySlot], _ groups: [PlaceGroup]) -> DaySlotPlan {
        DaySlotPolicy.assign(day: day, groups: groups, slots: slots)
    }
    func updated(_ plan: DaySlotPlan, _ slot: String?) -> DaySlotUpdate? { plan.updated.first { $0.slot == slot } }

    @Test func unnamedMainTakesTheOnlyGroup() {
        let p = plan([main(nil, nil)], [group("K", "Đà Lạt")])
        #expect(p.slotOfGroup == [nil])
        #expect(updated(p, nil)?.name == "Đà Lạt" && updated(p, nil)?.key == "K")
    }

    @Test func sameGroupChangesNothing() {
        let p = plan([main("K", "Đà Lạt")], [group("K", "Đà Lạt")])
        #expect(p.slotOfGroup == [nil])
        #expect(updated(p, nil)?.name == "Đà Lạt")
    }

    @Test func renamedGroupKeepsMainByKey() {
        let p = plan([main("K", "P. Cửa Nam")], [group("K", "Hà Nội")])
        #expect(p.slotOfGroup == [nil])
        #expect(updated(p, nil)?.name == "Hà Nội")
    }

    @Test func largestGroupStaysInPlaceInANeverNamedMain() {
        let p = plan([main(nil, nil)], [group("HN", "Hà Nội", ["1"]), group("NB", "Ninh Bình", ["2"])])
        #expect(p.slotOfGroup[0] == nil)
        let second = p.slotOfGroup[1]
        #expect(second != nil && second!.hasPrefix("p") && second!.count == 13)
        #expect(updated(p, second)?.name == "Ninh Bình")
    }

    @Test func unnamedGroupMatchesTheBareDateMain() {
        let p = plan([main(nil, nil)], [group("HN", "Hà Nội"), group(nil, nil)])
        #expect(p.slotOfGroup[1] == nil)
        #expect(p.slotOfGroup[0] != nil)
        #expect(updated(p, p.slotOfGroup[0])?.name == "Hà Nội")
    }

    @Test func nobodySwapsWhenSizesChange() {
        let p = plan([main("HN", "Hà Nội"), extra("pa0000000000", "NB", "Ninh Bình")], [group("NB", "Ninh Bình", ["1", "2"]), group("HN", "Hà Nội")])
        #expect(p.slotOfGroup == ["pa0000000000", nil])
    }

    @Test func namesMatchAndFillKeys() {
        let p = plan([main(nil, "Hà Nội"), extra("rabcdef012345", nil, "Ninh Bình")], [group("HN", "Hà Nội"), group("NB", "Ninh Bình")])
        #expect(p.slotOfGroup == [nil, "rabcdef012345"])
        #expect(updated(p, nil)?.key == "HN")
        #expect(updated(p, "rabcdef012345")?.key == "NB")
    }

    @Test func unusedSlotsAreFrozen() {
        let p = plan([main("HN", "Hà Nội"), extra("pa0000000000", "NB", "Ninh Bình")], [group("NB", "Ninh Bình")])
        #expect(p.slotOfGroup == ["pa0000000000"])
        #expect(p.updated.map(\.slot) == ["pa0000000000"])
    }

    @Test func twoUnnamedGroupsShareMain() {
        let p = plan([main(nil, nil)], [group(nil, nil, ["1"]), group(nil, nil, ["2"])])
        #expect(p.slotOfGroup == [nil, nil])
    }

    @Test func sameNameDifferentKeyReusesTheFolder() {
        let p = plan([main("HN", "Hà Nội"), extra("pa0000000000", "K1", "Ninh Bình")], [group("HN", "Hà Nội"), group("K2", "Ninh Bình")])
        #expect(p.slotOfGroup == [nil, "pa0000000000"])
    }

    @Test func nameStillOnDiskIsNotReusedByAnotherSlot() {
        let slots = [main("K", "Hà Nội", reserved: ["P. Cửa Nam"])]
        let p = plan(slots, [group("K", "Hà Nội"), group("K3", "P. Cửa Nam")])
        #expect(p.slotOfGroup == [nil, nil])
        #expect(p.deferredGroups == [1])
        assertInvariants(slots, [group("K", "Hà Nội"), group("K3", "P. Cửa Nam")], p)
    }

    @Test func pastNameOfARenamedSlotBlocksANewFolder() {
        let slots = [main("K1", "A"), extra("pa0000000000", "K2", "B")]
        let groups = [group("K2", "C"), group("K4", "B")]
        let p = plan(slots, groups)
        #expect(p.slotOfGroup[1] == "pa0000000000")
        #expect(p.slotOfGroup[0] != "pa0000000000")
        assertInvariants(slots, groups, p)
    }

    @Test func slugLengthensWhenItAlreadyExists() {
        let taken = DaySlotPolicy.slug(forKey: "NB")
        let slots = [main("HN", "Hà Nội"), extra(taken, "OTHER", "Đà Lạt")]
        let p = plan(slots, [group("HN", "Hà Nội"), group("NB", "Ninh Bình")])
        let slot = p.slotOfGroup[1]!
        #expect(slot != taken)
        #expect(slot.count == 17)
        #expect(slot.hasPrefix(taken))
    }

    @Test func slugsAreStableAndWellFormed() {
        #expect(DaySlotPolicy.slug(forKey: "VN|Hanoi") == DaySlotPolicy.slug(forKey: "VN|Hanoi"))
        #expect(DaySlotPolicy.slug(forKey: "VN|Hanoi") != DaySlotPolicy.slug(forKey: "VN|Ninh Binh"))
        for slug in [DaySlotPolicy.slug(forKey: nil), DaySlotPolicy.slug(forKey: "x"), DaySlotPolicy.slug(forRecoveredName: "2026-11-08 Hà Nội")] {
            #expect(DynamicLayout.isValidSlot(slug) && slug.count == 13)
        }
        #expect(DaySlotPolicy.slug(forRecoveredName: "2026-11-08 HÀ NỘI") == DaySlotPolicy.slug(forRecoveredName: "2026-11-08 hà nội"))
        #expect(DaySlotPolicy.slug(forRecoveredName: "x").hasPrefix("r"))
        #expect(DaySlotPolicy.slug(forKey: "x", digits: 20).count == 21)
    }

    @Test func newSlotsInOneRunGetDistinctSlugs() {
        let p = plan([main("HN", "Hà Nội")], [group("HN", "Hà Nội"), group("K", "X"), group("K", "Y")])
        let slots = Set(p.slotOfGroup.compactMap { $0 })
        #expect(slots.count == 2)
    }

    @Test func fuzzKeepsFolderNamesUniqueAndGroupsInTheirFolder() {
        var rng = SplitMix64(seed: 42)
        let names: [String?] = [nil, "Hà Nội", "ha noi", "Ninh Bình", "Đà Lạt", "Lào Cai"]
        let keys: [String?] = [nil, "K1", "K2", "K3"]
        for _ in 0..<1000 {
            var used: Set<String> = []
            func freshName() -> String? {
                for _ in 0..<20 {
                    let name = names[Int(rng.next() % UInt64(names.count))]
                    if used.insert(ck(name)).inserted { return name }
                }
                return "unique-\(used.count)"
            }
            var slots = [main(keys[Int(rng.next() % 4)], freshName())]
            for i in 0..<Int(rng.next() % 3) { slots.append(extra("p\(i)aaaaaaaaaaa", keys[Int(rng.next() % 4)], freshName())) }
            for i in slots.indices {
                for r in 0..<Int(rng.next() % 3) {
                    let candidate = names[Int(rng.next() % UInt64(names.count))]
                    if used.insert(ck(candidate)).inserted { slots[i].reservedNames.append(candidate) } else { _ = r }
                }
            }
            var groups: [PlaceGroup] = []
            var usedKeys: Set<String> = []
            for _ in 0..<Int(1 + rng.next() % 3) {
                let key = keys[Int(rng.next() % 4)]
                if let key, !usedKeys.insert(key).inserted { continue }
                groups.append(group(key, names[Int(rng.next() % UInt64(names.count))]))
            }
            let first = plan(slots, groups)
            #expect(first == plan(slots, groups))
            assertInvariants(slots, groups, first)
        }
    }

    func ck(_ name: String?) -> String { NameSanitizer.collisionKey(DynamicLayout.dayFolderName(day, placeName: name)) }

    /// (a) no two slots share a folder name, counting names still on disk; (b) a group's name is its folder's name;
    /// (d) a new slug never repeats an existing one.
    func assertInvariants(_ slots: [DaySlot], _ groups: [PlaceGroup], _ plan: DaySlotPlan, sourceLocation: SourceLocation = #_sourceLocation) {
        var names: [String?: [String]] = [:]
        for slot in slots {
            names[slot.slot, default: []] = [ck(slot.name)] + slot.reservedNames.map(ck)
        }
        var finals: [String?: String] = [:]
        for update in plan.updated {
            finals[update.slot] = ck(update.name)
            names[update.slot, default: []].append(ck(update.name))
        }
        for (slot, name) in finals {
            for (other, otherNames) in names where other != slot {
                #expect(!otherNames.contains(name), "folder name shared by two slots", sourceLocation: sourceLocation)
            }
        }
        for (index, group) in groups.enumerated() where !plan.deferredGroups.contains(index) {
            #expect(finals[plan.slotOfGroup[index]] == ck(group.name), "group not in a folder of its own name", sourceLocation: sourceLocation)
        }
        let existing = Set(slots.compactMap(\.slot))
        let created = plan.slotOfGroup.compactMap { $0 }.filter { !existing.contains($0) }
        #expect(Set(created).count == Set(plan.updated.compactMap(\.slot).filter { !existing.contains($0) }).count, sourceLocation: sourceLocation)
        #expect(plan.assetSlots.count == groups.flatMap(\.members).count, sourceLocation: sourceLocation)
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
