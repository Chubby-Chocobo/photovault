import Foundation

/// The assets of one camera day that share a province, with the name the day folder would carry.
public struct PlaceGroup: Hashable, Sendable {
    /// `<ISO>|<administrativeArea en>`; nil when the group is unnamed.
    public var key: String?
    public var name: String?
    /// `named` or `unnamed`.
    public var state: PlaceState
    /// Ids of the live assets, sorted.
    public var members: [String]

    public init(key: String?, name: String?, state: PlaceState, members: [String]) {
        self.key = key
        self.name = name
        self.state = state
        self.members = members
    }
}

public enum PlaceSplitResult: Hashable, Sendable {
    case pending
    /// Cells whose geocode answers are still missing, sorted.
    case waitingGeocode([GeoCell])
    /// Groups by member count (largest first), then key. `unassigned` are live assets without a
    /// creation date; they keep their current folder.
    case groups([PlaceGroup], unassigned: [String])
}

/// Splits the camera assets of one promoted day into one group per province. Pure: no geocoding, no clock.
///
/// While at most one province is known the day is named by `PlaceNamingPolicy` alone, so a one-province
/// day behaves exactly as before. Once two are known, every cell must have its English answer, and each
/// group is named on its own.
public enum PlaceSplitPolicy {
    public static func evaluate(_ input: PlaceNamingInput) -> PlaceSplitResult {
        let endedFor = input.now.timeIntervalSince(input.day.endDate(in: input.archiveTimeZone))
        guard endedFor >= PlaceNamingPolicy.minimumHoursAfterDayEnd * 3600 else { return .pending }

        let live = input.assets.filter { !$0.isDeleted }
        let usable = live.filter { $0.location != nil && (input.includeHidden || !$0.isHidden) }
        let cells = Set(usable.compactMap { $0.location.map(GeoCell.init) })
        let known = Set(cells.compactMap { input.englishGeocodes[$0].flatMap(PlaceNamingPolicy.identity) })

        if known.count <= 1 {
            let result = PlaceNamingPolicy.evaluate(input)
            if result.state == .waitingGeocode { return .waitingGeocode(result.cellsToGeocode) }
            // A box over 300 km reads as unnamed before any geocode is looked at; with answers missing it
            // may still turn out to be several provinces, so wait instead of renaming the day twice.
            let unanswered = cells.filter { input.englishGeocodes[$0] == nil }
            if result.state == .unnamed, !unanswered.isEmpty { return .waitingGeocode(unanswered.sorted()) }
            let group = PlaceGroup(key: result.placeKey, name: result.placeName, state: result.state, members: live.map(\.id).sorted())
            return .groups([group], unassigned: [])
        }

        let uncached = cells.filter { input.englishGeocodes[$0] == nil }
        if !uncached.isEmpty { return .waitingGeocode(uncached.sorted()) }

        var anchorsByKey: [String: [PlaceAsset]] = [:]
        var anchorIds: Set<String> = []
        for asset in usable {
            guard let point = asset.location, let identity = input.englishGeocodes[GeoCell(point)].flatMap(PlaceNamingPolicy.identity)
            else { continue }
            anchorsByKey[identity.key, default: []].append(asset)
            anchorIds.insert(asset.id)
        }

        var members = anchorsByKey.mapValues { $0.map(\.id) }
        var unassigned: [String] = []
        let dated = anchorsByKey.flatMap { key, assets in assets.compactMap { a in a.creationDate.map { (key, a.id, $0) } } }
        for asset in live where !anchorIds.contains(asset.id) {
            guard let date = asset.creationDate, let nearest = dated.min(by: { closer($0, $1, to: date) }) else {
                unassigned.append(asset.id)
                continue
            }
            members[nearest.0, default: []].append(asset.id)
        }

        var groups: [PlaceGroup] = []
        var waiting: Set<GeoCell> = []
        for (key, anchors) in anchorsByKey {
            var sub = input
            sub.assets = anchors
            let result = PlaceNamingPolicy.evaluate(sub)
            if result.state == .waitingGeocode {
                waiting.formUnion(result.cellsToGeocode)
                continue
            }
            let named = result.state == .named
            groups.append(PlaceGroup(
                key: named ? result.placeKey : nil, name: named ? result.placeName : nil,
                state: named ? .named : .unnamed, members: (members[key] ?? []).sorted()))
        }
        if !waiting.isEmpty { return .waitingGeocode(waiting.sorted()) }

        groups.sort { ($0.members.count, $1.key ?? "") > ($1.members.count, $0.key ?? "") }
        return .groups(groups, unassigned: unassigned.sorted())
    }

    /// Orders anchors by distance in time to `date`; ties go to the earlier anchor, then the smaller id.
    private static func closer(_ a: (String, String, Date), _ b: (String, String, Date), to date: Date) -> Bool {
        let da = abs(a.2.timeIntervalSince(date)), db = abs(b.2.timeIntervalSince(date))
        if da != db { return da < db }
        if a.2 != b.2 { return a.2 < b.2 }
        return a.1 < b.1
    }
}
