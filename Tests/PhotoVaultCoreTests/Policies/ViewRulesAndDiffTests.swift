import Foundation
import Testing
@testable import PhotoVaultCore

@Suite struct ViewRulesTests {
    let daLat = GeoPoint(latitude: 11.9404, longitude: 108.4583)
    let day = ArchiveDay(year: 2025, month: 3, day: 1)!
    func fixtureAsset(_ key: String = "l:A", category: AssetCategory? = .camera, make: String? = "SONY", model: String? = "ILCE-7M4",
                      favorite: Bool = false, hidden: Bool = false, location: GeoPoint? = nil, noDay: Bool = false) -> AssetRecord {
        PolicyFixtures.asset(key, category: category, day: noDay ? nil : day, make: make, model: model, favorite: favorite, hidden: hidden, location: location)
    }

    @Test func byDeviceUsesDefaultGroupAndTableName() {
        let path = ViewRules.path(for: fixtureAsset(), in: .byDevice, context: ViewContext())
        let key = DeviceNameResolver.key(make: "SONY", model: "ILCE-7M4")
        #expect(path == .byDevice(groupKey: DeviceNameResolver.groupId(forKey: key), groupName: "Sony A7 IV", day: day))
    }

    @Test func byDeviceHonoursMergedGroupAndRename() {
        let key = DeviceNameResolver.key(make: "SONY", model: "ILCE-7M4")
        let context = ViewContext(deviceGroupByModelKey: [key: "grp1"], deviceGroupNames: ["grp1": "Máy của Nam"])
        #expect(ViewRules.path(for: fixtureAsset(), in: .byDevice, context: context) == .byDevice(groupKey: "grp1", groupName: "Máy của Nam", day: day))
    }

    @Test func byDeviceNeedsCameraCategoryAndModel() {
        #expect(ViewRules.path(for: fixtureAsset(category: .saved), in: .byDevice, context: ViewContext()) == nil)
        #expect(ViewRules.path(for: fixtureAsset(model: nil), in: .byDevice, context: ViewContext()) == nil)
        #expect(ViewRules.path(for: fixtureAsset(model: "  "), in: .byDevice, context: ViewContext()) == nil)
    }

    @Test func favoritesAcceptsAnyCategory() {
        for category in AssetCategory.allCases {
            #expect(ViewRules.path(for: fixtureAsset(category: category, favorite: true), in: .favorites, context: ViewContext()) == .favorites(day: day))
        }
        #expect(ViewRules.path(for: fixtureAsset(favorite: false), in: .favorites, context: ViewContext()) == nil)
    }

    @Test func byPlaceUsesEnglishKeysAndDisplayNames() {
        let en = GeoPlace(isoCountryCode: "vn", country: "Vietnam", administrativeArea: "Lam Dong", locality: "Da Lat")
        let vi = GeoPlace(isoCountryCode: "VN", country: "Việt Nam", administrativeArea: "Lâm Đồng", locality: "Đà Lạt")
        let cell = GeoCell(daLat)
        let context = ViewContext(englishGeocodes: [cell: en], displayGeocodes: [cell: vi])
        let path = ViewRules.path(for: fixtureAsset(location: daLat), in: .byPlace, context: context)
        #expect(path == .byPlace(countryKey: "VN", countryName: "Việt Nam", areaKey: "Lam Dong", areaName: "Lâm Đồng", day: day))
        let englishOnly = ViewContext(englishGeocodes: [cell: en])
        #expect(ViewRules.path(for: fixtureAsset(location: daLat), in: .byPlace, context: englishOnly)
                == .byPlace(countryKey: "VN", countryName: "Vietnam", areaKey: "Lam Dong", areaName: "Lam Dong", day: day))
    }

    @Test func byPlaceRequiresGpsGeocodeAndRespectsHidden() {
        let en = GeoPlace(isoCountryCode: "VN", country: "Vietnam", administrativeArea: "Lam Dong")
        let context = ViewContext(englishGeocodes: [GeoCell(daLat): en])
        #expect(ViewRules.path(for: fixtureAsset(), in: .byPlace, context: context) == nil)
        #expect(ViewRules.path(for: fixtureAsset(location: daLat), in: .byPlace, context: ViewContext()) == nil)
        #expect(ViewRules.path(for: fixtureAsset(hidden: true, location: daLat), in: .byPlace, context: context) == nil)
        var withHidden = context
        withHidden.includeHidden = true
        #expect(ViewRules.path(for: fixtureAsset(hidden: true, location: daLat), in: .byPlace, context: withHidden) != nil)
        let noArea = ViewContext(englishGeocodes: [GeoCell(daLat): GeoPlace(isoCountryCode: "VN", country: "Vietnam")])
        #expect(ViewRules.path(for: fixtureAsset(location: daLat), in: .byPlace, context: noArea) == nil)
    }

    @Test func aDeletedAssetKeepsItsPathInEveryView() {
        let context = ViewContext(englishGeocodes: [GeoCell(daLat): GeoPlace(isoCountryCode: "VN", country: "Vietnam", administrativeArea: "Lam Dong")])
        let live = fixtureAsset(favorite: true, location: daLat)
        var deleted = live
        deleted.deletedAt = Date(timeIntervalSince1970: 1_000)
        #expect(ViewRules.paths(for: deleted, context: context) == ViewRules.paths(for: live, context: context))
        #expect(ViewRules.paths(for: deleted, context: context).count == 3)
    }

    @Test func areaKeyIsSafeForLogicalPaths() {
        let en = GeoPlace(isoCountryCode: "XX", country: "X", administrativeArea: "A/B")
        let context = ViewContext(englishGeocodes: [GeoCell(daLat): en])
        guard case let .byPlace(_, _, areaKey, _, _)? = ViewRules.path(for: fixtureAsset(location: daLat), in: .byPlace, context: context) else {
            Issue.record("expected a place path")
            return
        }
        #expect(!areaKey.contains("/"))
    }

    @Test func assetsWithoutDayBelongToNoView() {
        let en = GeoPlace(isoCountryCode: "VN", country: "Vietnam", administrativeArea: "Lam Dong")
        let context = ViewContext(englishGeocodes: [GeoCell(daLat): en])
        #expect(ViewRules.paths(for: fixtureAsset(favorite: true, location: daLat, noDay: true), context: context).isEmpty)
        var unplaced = fixtureAsset(favorite: true)
        unplaced.placement = nil
        #expect(ViewRules.paths(for: unplaced, context: context).isEmpty)
    }

    @Test func pathsReturnsEveryMatchingView() {
        let en = GeoPlace(isoCountryCode: "VN", country: "Vietnam", administrativeArea: "Lam Dong")
        let context = ViewContext(englishGeocodes: [GeoCell(daLat): en])
        let views = ViewRules.paths(for: fixtureAsset(favorite: true, location: daLat), context: context).map(\.view)
        #expect(Set(views) == Set(ViewKind.allCases))
    }
}

@Suite struct ViewDiffTests {
    let a = AssetKey.local("A"), b = AssetKey.local("B"), c = AssetKey.local("C")
    let dest = DestinationID.googleDrive

    func record(_ key: AssetKey, _ state: ShortcutState = .done, parent: String = "p1", target: String? = "t1", view: ViewKind = .favorites) -> ShortcutRecord {
        ShortcutRecord(destinationId: dest, view: view, assetKey: key, targetId: target, shortcutId: "s-\(key.identifier)", parentLogical: parent, state: state)
    }

    func want(_ key: AssetKey, parent: String = "p1", target: String? = "t1", view: ViewKind = .favorites) -> DesiredShortcut {
        DesiredShortcut(assetKey: key, view: view, parentLogical: parent, targetId: target)
    }

    @Test func missingWithDoneTargetIsCreatedAndWithoutTargetIsSkipped() {
        let ops = ViewDiff.operations(desired: [want(a), want(b, target: nil)], current: [])
        #expect(ops == [.create(want(a))])
    }

    @Test func inSyncProducesNothing() {
        #expect(ViewDiff.operations(desired: [want(a)], current: [record(a)]).isEmpty)
    }

    @Test func differentParentMoves() {
        let ops = ViewDiff.operations(desired: [want(a, parent: "p2")], current: [record(a)])
        #expect(ops == [.move(view: .favorites, assetKey: a, toParentLogical: "p2")])
    }

    @Test func changedTargetTrashesThenCreates() {
        let ops = ViewDiff.operations(desired: [want(a, target: "t2")], current: [record(a)])
        #expect(ops == [.trash(view: .favorites, assetKey: a), .create(want(a, target: "t2"))])
    }

    @Test func changedTargetAndParentDoesNotAlsoMove() {
        let ops = ViewDiff.operations(desired: [want(a, parent: "p2", target: "t2")], current: [record(a)])
        #expect(ops == [.trash(view: .favorites, assetKey: a), .create(want(a, parent: "p2", target: "t2"))])
    }

    @Test func extraShortcutIsTrashedOnce() {
        let ops = ViewDiff.operations(desired: [], current: [record(a), record(b, .trashed), record(c, .trashPending)])
        #expect(ops == [.trash(view: .favorites, assetKey: a)])
    }

    @Test func userRemovedIsLeftAlone() {
        let current = [record(a, .userRemoved)]
        #expect(ViewDiff.operations(desired: [want(a)], current: current).isEmpty)
        #expect(ViewDiff.operations(desired: [], current: current).isEmpty)
        #expect(ViewDiff.operations(desired: [want(a, parent: "p9", target: "t9")], current: current).isEmpty)
    }

    @Test func trashedShortcutIsRecreatedWhenDesiredAgain() {
        #expect(ViewDiff.operations(desired: [want(a)], current: [record(a, .trashed)]) == [.create(want(a))])
        #expect(ViewDiff.operations(desired: [want(a, target: nil)], current: [record(a, .trashed)]).isEmpty)
    }

    @Test func unfinishedTargetKeepsExistingShortcut() {
        #expect(ViewDiff.operations(desired: [want(a, target: nil)], current: [record(a)]).isEmpty)
    }

    @Test func trashAndMoveComeBeforeCreate() {
        let desired = [want(c), want(b, parent: "p2"), want(a, target: "t2")]
        let current = [record(a), record(b), record(.local("Z"))]
        let ops = ViewDiff.operations(desired: desired, current: current)
        #expect(ops == [
            .trash(view: .favorites, assetKey: a), .trash(view: .favorites, assetKey: .local("Z")),
            .move(view: .favorites, assetKey: b, toParentLogical: "p2"),
            .create(want(a, target: "t2")), .create(want(c)),
        ])
    }

    @Test func viewsAreIndependentAndOrderIsDeterministic() {
        let desired = [want(a, view: .byDevice), want(a, view: .favorites)]
        let current = [record(a, view: .byPlace)]
        let first = ViewDiff.operations(desired: desired, current: current)
        let second = ViewDiff.operations(desired: desired.reversed(), current: current)
        #expect(first == second)
        #expect(first == [.trash(view: .byPlace, assetKey: a), .create(want(a, view: .byDevice)), .create(want(a, view: .favorites))])
    }

    @Test func pendingRecordIsCreatedNotMovedOrTrashedRemotely() {
        #expect(ViewDiff.operations(desired: [want(a, parent: "p2")], current: [record(a, .pending, target: nil)]) == [.create(want(a, parent: "p2"))])
    }
}
