import Foundation

/// The slice of an asset the place algorithm needs (camera assets of one promoted day).
public struct PlaceAsset: Hashable, Sendable {
    public var location: GeoPoint?
    public var isHidden: Bool
    public var isDeleted: Bool
    /// Identifies the asset in a split result; empty where only the location matters.
    public var id: String
    public var creationDate: Date?

    public init(
        location: GeoPoint?, isHidden: Bool = false, isDeleted: Bool = false, id: String = "", creationDate: Date? = nil
    ) {
        self.location = location
        self.isHidden = isHidden
        self.isDeleted = isDeleted
        self.id = id
        self.creationDate = creationDate
    }
}

public struct PlaceNamingInput: Sendable {
    public var assets: [PlaceAsset]
    /// "Hidden upload" setting; hidden assets feed place names only when it is on.
    public var includeHidden: Bool
    /// Cached geocodes keyed by cell, locale `en` (identity keys).
    public var englishGeocodes: [GeoCell: GeoPlace]
    /// Cached geocodes in each cell's second locale (`PlaceNameRule.secondLocale`), for names.
    public var localGeocodes: [GeoCell: GeoPlace]
    public var homeCountryCode: String
    public var day: ArchiveDay
    public var archiveTimeZone: TimeZone
    public var now: Date

    public init(
        assets: [PlaceAsset], includeHidden: Bool, englishGeocodes: [GeoCell: GeoPlace],
        localGeocodes: [GeoCell: GeoPlace], homeCountryCode: String,
        day: ArchiveDay, archiveTimeZone: TimeZone, now: Date
    ) {
        self.assets = assets
        self.includeHidden = includeHidden
        self.englishGeocodes = englishGeocodes
        self.localGeocodes = localGeocodes
        self.homeCountryCode = homeCountryCode
        self.day = day
        self.archiveTimeZone = archiveTimeZone
        self.now = now
    }
}

public struct PlaceNamingResult: Hashable, Sendable {
    public var state: PlaceState
    /// `<ISO>|<administrativeArea en>` when named.
    public var placeKey: String?
    public var placeName: String?
    /// Representative cells still missing a geocode in `en` or in their second locale.
    public var cellsToGeocode: [GeoCell]
}

/// Day-folder place naming (FR-80..83, 8.11). Pure: no geocoding, no clock.
public enum PlaceNamingPolicy {
    public static let maxBoundingBoxKm = 300.0
    public static let maxCells = 30
    public static let minimumHoursAfterDayEnd = 6.0

    public static func evaluate(_ input: PlaceNamingInput) -> PlaceNamingResult {
        let unnamed = PlaceNamingResult(state: .unnamed, placeKey: nil, placeName: nil, cellsToGeocode: [])
        let endedFor = input.now.timeIntervalSince(input.day.endDate(in: input.archiveTimeZone))
        guard endedFor >= minimumHoursAfterDayEnd * 3600 else {
            return PlaceNamingResult(state: .pending, placeKey: nil, placeName: nil, cellsToGeocode: [])
        }

        let cells = Set(input.assets.compactMap { asset -> GeoCell? in
            guard !asset.isDeleted, input.includeHidden || !asset.isHidden, let point = asset.location else { return nil }
            return GeoCell(point)
        })
        guard !cells.isEmpty, boundingBoxDiagonalKm(of: cells) <= maxBoundingBoxKm else { return unnamed }

        let representatives = representativeCells(cells)
        let known = representatives.compactMap { cell in
            input.englishGeocodes[cell].flatMap(identity).map { (cell, $0) }
        }
        if Set(known.map(\.1.key)).count > 1 { return unnamed }

        let missing = representatives.filter { cell in
            guard let english = input.englishGeocodes[cell] else { return true }
            guard let identity = identity(english) else { return false }
            return PlaceNameRule.secondLocale(country: identity.iso) != nil && input.localGeocodes[cell] == nil
        }
        if !missing.isEmpty {
            return PlaceNamingResult(state: .waitingGeocode, placeKey: nil, placeName: nil, cellsToGeocode: missing)
        }
        guard let identityKey = known.first?.1 else { return unnamed }

        return PlaceNamingResult(
            state: .named, placeKey: identityKey.key, placeName: displayName(input, usable: known.map(\.0), identity: identityKey),
            cellsToGeocode: []
        )
    }

    /// Identity of a geocode: ISO country + administrative area; nil when either is missing.
    struct PlaceIdentity: Hashable {
        var iso: String
        var area: String
        var key: String { "\(iso)|\(area)" }
    }

    static func identity(_ place: GeoPlace) -> PlaceIdentity? {
        guard let iso = place.isoCountryCode?.trimmingCharacters(in: .whitespaces), !iso.isEmpty,
              let area = place.administrativeArea?.trimmingCharacters(in: .whitespaces), !area.isEmpty else { return nil }
        return PlaceIdentity(iso: iso.uppercased(), area: area)
    }

    private static func displayName(_ input: PlaceNamingInput, usable: [GeoCell], identity: PlaceIdentity) -> String {
        let english = usable.compactMap { input.englishGeocodes[$0] }
        let display = usable.compactMap { cell in
            input.englishGeocodes[cell].map { PlaceNameRule.display(english: $0, local: input.localGeocodes[cell]) }
        }

        let localities = english.map { $0.locality?.trimmingCharacters(in: .whitespaces) ?? "" }
        let sameLocality = !localities.contains("") && Set(localities).count == 1
        let localityName = display.compactMap(\.locality).first { !$0.isEmpty }
        let areaName = display.compactMap(\.administrativeArea).first { !$0.isEmpty } ?? identity.area

        var name = sameLocality ? (localityName ?? areaName) : areaName
        if identity.iso != input.homeCountryCode.uppercased() {
            let country = display.compactMap(\.country).first { !$0.isEmpty }
                ?? english.compactMap(\.country).first { !$0.isEmpty } ?? identity.iso
            name += ", \(country)"
        }
        return name
    }

    /// At most `limit` cells, always including the northmost, southmost, eastmost and westmost,
    /// the rest spread evenly over the sorted cells; deterministic for a given set.
    public static func representativeCells(_ cells: Set<GeoCell>, limit: Int = maxCells) -> [GeoCell] {
        let sorted = cells.sorted()
        guard sorted.count > limit, let north = sorted.last, let south = sorted.first,
              let east = sorted.max(by: { ($0.lonIndex, $0.latIndex) < ($1.lonIndex, $1.latIndex) }),
              let west = sorted.min(by: { ($0.lonIndex, $0.latIndex) < ($1.lonIndex, $1.latIndex) }) else { return sorted }
        var chosen: Set<GeoCell> = [north, south, east, west]
        for step in 0..<limit where chosen.count < limit {
            chosen.insert(sorted[step * sorted.count / limit])
        }
        for cell in sorted where chosen.count < limit { chosen.insert(cell) }
        return chosen.sorted()
    }

    /// Haversine distance between the bounding box corners of the cell centres.
    static func boundingBoxDiagonalKm(of cells: Set<GeoCell>) -> Double {
        let centers = cells.map(\.center)
        guard let minLat = centers.map(\.latitude).min(), let maxLat = centers.map(\.latitude).max(),
              let minLon = centers.map(\.longitude).min(), let maxLon = centers.map(\.longitude).max() else { return 0 }
        return haversineKm(GeoPoint(latitude: minLat, longitude: minLon), GeoPoint(latitude: maxLat, longitude: maxLon))
    }

    static func haversineKm(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let radius = 6371.0088
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * asin(min(1, sqrt(h)))
    }
}
