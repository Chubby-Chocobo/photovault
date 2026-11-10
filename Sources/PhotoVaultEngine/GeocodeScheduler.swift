import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Reverse geocoding of missing grid cells (FR-84, spec 8.11) at most 20 requests per sliding
/// minute, with exponential backoff after errors. Results are cached forever per cell for `en`
/// (identity keys and English names) and for the cell's second locale (`PlaceNameRule`), kept under
/// the key `local`. The newest cells go first. Only the cell centre leaves the Mac (FR-85); with place names off nothing is sent.
actor GeocodeScheduler {
    static let requestsPerMinute = 20
    private static let window: TimeInterval = 60
    /// Consecutive results with a country but no province before the structured fields are
    /// considered lost and the names fall back to the country. Water cells (a bay, a lake, a boat
    /// trip) answer with a country and no province, so a short run of them proves nothing; and once
    /// any answer carried a province the fields are known to work and the fallback never starts.
    private static let lostFieldThreshold = 10
    static let countryOnlyKey = "place_country_only"
    /// Set when an `en` answer carried a province since the last refresh.
    private static let provinceSeenKey = "geo_province_seen"
    /// Answers fetched before this moment are asked for again (the owner's "Làm mới địa danh").
    private static let refreshSinceKey = "geo_refresh_since"

    private let env: EngineEnvironment
    private var requestTimes: [Date] = []
    private var failures = 0
    private var blockedUntil: Date?
    private var noProvinceStreak = 0
    private var provinceSeen: Bool?

    init(env: EngineEnvironment) { self.env = env }

    private struct Need: Sendable {
        var cell: GeoCell
        var hasEnglish: Bool
        var hasLocal: Bool
    }

    /// Geocodes what the budget allows; returns the number of requests made.
    func runPass() async throws -> Int {
        guard let geocoder = env.geocoder else { return 0 }
        let settings = await env.settingsSnapshot().settings
        guard settings.placeNamesEnabled, await env.system.snapshot().networkAvailable else { return 0 }
        if let until = blockedUntil, until > env.clock.now { return 0 }
        let localKey = OrganizationLookups.localLocaleKey
        var requests = 0
        var skip = Set<GeoCell>()
        while true {
            try Task.checkCancellation()
            let needs = try await missing(settings: settings, limit: 25 + skip.count).filter { !skip.contains($0.cell) }
            if needs.isEmpty { return requests }
            for need in needs {
                skip.insert(need.cell)
                var english: GeoPlace?
                if !need.hasEnglish {
                    guard let place = try await request(geocoder, need.cell, locale: "en", &requests) else { return requests }
                    english = place
                }
                guard !need.hasLocal else { continue }
                if english == nil {
                    let cell = need.cell
                    english = try await env.store.read { db in try GeoCacheRepository.fetch(db, cell: cell, locale: "en")?.place }
                }
                guard let english else { continue }
                guard Self.identity(english) != nil, let locale = PlaceNameRule.secondLocale(country: english.isoCountryCode ?? "") else {
                    // Nothing to name, or an English-speaking country: the English answer stands in for
                    // the second one instead of asking again.
                    try await save(need.cell, locale: localKey, place: english)
                    continue
                }
                guard try await request(geocoder, need.cell, locale: locale, saveAs: localKey, &requests) != nil else { return requests }
            }
        }
    }

    /// One request when the minute budget allows; nil when blocked (budget or backoff).
    private func request(
        _ geocoder: any ReverseGeocoding, _ cell: GeoCell, locale: String, saveAs key: String? = nil, _ count: inout Int
    ) async throws -> GeoPlace? {
        let now = env.clock.now
        requestTimes.removeAll { now.timeIntervalSince($0) >= Self.window }
        guard requestTimes.count < Self.requestsPerMinute else { return nil }
        requestTimes.append(now)
        count += 1
        let place: GeoPlace
        do {
            place = try await geocoder.reverseGeocode(cell: cell, locale: locale)
        } catch {
            if error is EngineAbort || error is CancellationError { throw error }
            failures += 1
            blockedUntil = env.clock.now.addingTimeInterval(Backoff().delay(forAttempt: failures - 1))
            env.log.log(.notice, category: "geocode", "geocoding failed; backing off")
            return nil
        }
        failures = 0
        blockedUntil = nil
        let stored = try await adapt(place, locale: locale)
        try await save(cell, locale: key ?? locale, place: stored)
        return stored
    }

    // MARK: Storage

    private func save(_ cell: GeoCell, locale: String, place: GeoPlace) async throws {
        let entry = GeoCacheEntry(cell: cell, locale: locale, place: place, fetchedAt: env.clock.now)
        try await env.store.write { db in
            let previous = try GeoCacheRepository.fetch(db, cell: cell, locale: locale)?.place
            try GeoCacheRepository.save(db, entry)
            // An answer that did not change leaves sidecars, descriptions and views as they are.
            if previous != place { try DirtyQueue.markAssets(db, inCell: cell) }
        }
    }

    /// Country-only fallback ([VERIFY M0-6]): when results keep arriving without a province the
    /// province is taken to be the country, so folders are still named, and the owner is told once.
    private func adapt(_ place: GeoPlace, locale: String) async throws -> GeoPlace {
        let hasProvince = !(place.administrativeArea ?? "").isEmpty
        if locale == "en" {
            if hasProvince {
                noProvinceStreak = 0
                try await noteProvinceSeen()
            } else if place.isoCountryCode != nil, place.country != nil {
                noProvinceStreak += 1
            }
        }
        let (countryOnly, seen) = try await env.store.read { db in
            (try KeyValueRepository.int(db, Self.countryOnlyKey) == 1, try KeyValueRepository.int(db, Self.provinceSeenKey) == 1)
        }
        let fieldsLost = !seen && noProvinceStreak >= Self.lostFieldThreshold
        if !countryOnly, fieldsLost { try await enterCountryOnly() }
        guard fieldsLost || countryOnly, !hasProvince, let country = place.country else { return place }
        return GeoPlace(isoCountryCode: place.isoCountryCode, country: nil, administrativeArea: country, locality: nil)
    }

    /// A province arrived: the structured fields work. A country-only fallback started earlier is
    /// undone; the cells it rewrote are asked again and keep their own (often empty) province.
    private func noteProvinceSeen() async throws {
        guard provinceSeen != true else { return }
        provinceSeen = true
        let now = env.clock.now
        try await env.store.write { db in
            try KeyValueRepository.set(db, Self.provinceSeenKey, 1)
            guard try KeyValueRepository.int(db, Self.countryOnlyKey) == 1 else { return }
            try KeyValueRepository.set(db, Self.countryOnlyKey, nil)
            // Rewritten answers are the only ones with a province and no country.
            try db.execute(sql: """
                DELETE FROM geo_cache WHERE geo_cell IN (
                    SELECT geo_cell FROM geo_cache WHERE country IS NULL AND administrative_area IS NOT NULL)
                """)
            for day in try OrganizationQueries.promotedDays(db) { try DirtyQueue.mark(db, [.place], id: day.description) }
            try ActivityRepository.record(db, ActivityEvent(
                at: now, kind: .notice, message: tr(
                    vi: "Apple đã trả về tỉnh/thành; địa danh dùng lại tên tỉnh",
                    en: "Apple returned the province/city again; place names use the province name")))
        }
    }

    private func enterCountryOnly() async throws {
        let now = env.clock.now
        try await env.store.write { db in
            try KeyValueRepository.set(db, Self.countryOnlyKey, 1)
            // Second-locale answers of those cells are asked again, so every name is country-level.
            try db.execute(sql: """
                DELETE FROM geo_cache WHERE locale != 'en' AND geo_cell IN (
                    SELECT geo_cell FROM geo_cache WHERE locale = 'en'
                      AND (administrative_area IS NULL OR administrative_area = '') AND country IS NOT NULL)
                """)
            try db.execute(sql: """
                UPDATE geo_cache SET administrative_area = country, locality = NULL, country = NULL
                WHERE (administrative_area IS NULL OR administrative_area = '') AND country IS NOT NULL
                """)
            for day in try OrganizationQueries.promotedDays(db) { try DirtyQueue.mark(db, [.place], id: day.description) }
            try ActivityRepository.record(db, ActivityEvent(
                at: now, kind: .notice, message: tr(
                    vi: "Apple không trả về tỉnh/thành; địa danh dùng tên quốc gia",
                    en: "Apple did not return a province/city; place names use the country name")))
        }
    }

    private static func identity(_ place: GeoPlace) -> String? {
        guard let iso = place.isoCountryCode, !iso.isEmpty, let area = place.administrativeArea, !area.isEmpty else { return nil }
        return iso + "|" + area
    }

    // MARK: Queries

    private func missing(settings: GlobalSettings, limit: Int) async throws -> [Need] {
        let localKey = OrganizationLookups.localLocaleKey
        return try await env.store.read { db in
            let since = try KeyValueRepository.date(db, Self.refreshSinceKey) ?? .distantPast
            return try Row.fetchAll(db, sql: """
                SELECT a.geo_cell AS cell,
                    MAX(CASE WHEN d.promoted = 1 THEN 1 ELSE 0 END) AS prio, MAX(a.creation_date) AS newest,
                    EXISTS(SELECT 1 FROM geo_cache g WHERE g.geo_cell = a.geo_cell AND g.locale = 'en' AND g.fetched_at >= :since) AS hasEn,
                    EXISTS(SELECT 1 FROM geo_cache g WHERE g.geo_cell = a.geo_cell AND g.locale = :local AND g.fetched_at >= :since) AS hasLocal
                FROM asset a LEFT JOIN day_stat d ON d.day = a.placement_day
                WHERE a.geo_cell IS NOT NULL AND a.category = 'camera' AND a.deleted_at IS NULL
                  AND (:hidden = 1 OR a.is_hidden = 0)
                GROUP BY a.geo_cell
                HAVING hasEn = 0 OR hasLocal = 0
                ORDER BY prio DESC, newest DESC, a.geo_cell
                LIMIT :limit
                """, arguments: ["local": localKey, "hidden": settings.includeHidden, "limit": limit, "since": since]).compactMap { row in
                (row["cell"] as String?).flatMap(GeoCell.init(key:)).map {
                    Need(cell: $0, hasEnglish: (row["hasEn"] as Int) == 1, hasLocal: (row["hasLocal"] as Int) == 1)
                }
            }
        }
    }

    // MARK: Refresh

    /// FR-106 "Làm mới địa danh": every cell is asked again. The answers on hand stay in use meanwhile
    /// (nothing is renamed or removed while the requests are on their way); a cell whose answer
    /// really changed marks its assets, and only those are rewritten.
    func refreshAll() async throws {
        let now = env.clock.now
        try await env.store.write { db in
            try KeyValueRepository.set(db, Self.refreshSinceKey, now)
            try KeyValueRepository.set(db, Self.countryOnlyKey, nil)
            try KeyValueRepository.set(db, Self.provinceSeenKey, nil)
        }
        noProvinceStreak = 0
        provinceSeen = nil
    }
}
