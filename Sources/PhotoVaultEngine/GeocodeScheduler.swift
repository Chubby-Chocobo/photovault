import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Reverse geocoding of missing grid cells (FR-84, spec 8.11) at most 20 requests per sliding
/// minute, with exponential backoff after errors. Results are cached forever per (cell, locale) for
/// `en` (identity keys) and the display language. Cells of promoted day folders go first, then the
/// newest cells. Only the cell centre leaves the Mac (FR-85); with place names off nothing is sent.
actor GeocodeScheduler {
    static let requestsPerMinute = 20
    private static let window: TimeInterval = 60
    /// Consecutive results with a country but no province before the structured fields are
    /// considered lost and the names fall back to the country.
    private static let lostFieldThreshold = 3
    private static let countryOnlyKey = "place_country_only"

    private let env: EngineEnvironment
    private var requestTimes: [Date] = []
    private var failures = 0
    private var blockedUntil: Date?
    private var noProvinceStreak = 0

    init(env: EngineEnvironment) { self.env = env }

    private struct Need: Sendable {
        var cell: GeoCell
        var hasEnglish: Bool
        var hasDisplay: Bool
    }

    /// Geocodes what the budget allows; returns the number of requests made.
    func runPass() async throws -> Int {
        guard let geocoder = env.geocoder else { return 0 }
        let settings = await env.settingsSnapshot().settings
        guard settings.placeNamesEnabled, await env.system.snapshot().networkAvailable else { return 0 }
        if let until = blockedUntil, until > env.clock.now { return 0 }
        let language = settings.placeNameLanguage
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
                guard language != "en", !need.hasDisplay else { continue }
                if english == nil {
                    let cell = need.cell
                    english = try await env.store.read { db in try GeoCacheRepository.fetch(db, cell: cell, locale: "en")?.place }
                }
                if let english, Self.identity(english) == nil {
                    // Nothing to name: keep the same (empty) answer for the display language instead of asking again.
                    try await save(need.cell, locale: language, place: english)
                    continue
                }
                guard try await request(geocoder, need.cell, locale: language, &requests) != nil else { return requests }
            }
        }
    }

    /// One request when the minute budget allows; nil when blocked (budget or backoff).
    private func request(_ geocoder: any ReverseGeocoding, _ cell: GeoCell, locale: String, _ count: inout Int) async throws -> GeoPlace? {
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
        try await save(cell, locale: locale, place: stored)
        return stored
    }

    // MARK: Storage

    private func save(_ cell: GeoCell, locale: String, place: GeoPlace) async throws {
        let entry = GeoCacheEntry(cell: cell, locale: locale, place: place, fetchedAt: env.clock.now)
        try await env.store.write { db in
            try GeoCacheRepository.save(db, entry)
            try DirtyQueue.markAssets(db, inCell: cell)
        }
    }

    /// Country-only fallback ([VERIFY M0-6]): when results keep arriving without a province the
    /// province is taken to be the country, so folders are still named, and the owner is told once.
    private func adapt(_ place: GeoPlace, locale: String) async throws -> GeoPlace {
        let hasProvince = !(place.administrativeArea ?? "").isEmpty
        if locale == "en" {
            if hasProvince {
                noProvinceStreak = 0
            } else if place.isoCountryCode != nil, place.country != nil {
                noProvinceStreak += 1
            }
        }
        let countryOnly = try await env.store.read { db in try KeyValueRepository.int(db, Self.countryOnlyKey) } == 1
        if !countryOnly, noProvinceStreak >= Self.lostFieldThreshold { try await enterCountryOnly() }
        guard noProvinceStreak >= Self.lostFieldThreshold || countryOnly, !hasProvince, let country = place.country else { return place }
        return GeoPlace(isoCountryCode: place.isoCountryCode, country: nil, administrativeArea: country, locality: nil)
    }

    private func enterCountryOnly() async throws {
        let now = env.clock.now
        try await env.store.write { db in
            try KeyValueRepository.set(db, Self.countryOnlyKey, 1)
            // Display-language answers of those cells are asked again, so every name is country-level.
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
                at: now, kind: .notice, message: "Apple không trả về tỉnh/thành; địa danh dùng tên quốc gia"))
        }
    }

    private static func identity(_ place: GeoPlace) -> String? {
        guard let iso = place.isoCountryCode, !iso.isEmpty, let area = place.administrativeArea, !area.isEmpty else { return nil }
        return iso + "|" + area
    }

    // MARK: Queries

    private func missing(settings: GlobalSettings, limit: Int) async throws -> [Need] {
        let language = settings.placeNameLanguage
        return try await env.store.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.geo_cell AS cell,
                    MAX(CASE WHEN d.promoted = 1 THEN 1 ELSE 0 END) AS prio, MAX(a.creation_date) AS newest,
                    EXISTS(SELECT 1 FROM geo_cache g WHERE g.geo_cell = a.geo_cell AND g.locale = 'en') AS hasEn,
                    EXISTS(SELECT 1 FROM geo_cache g WHERE g.geo_cell = a.geo_cell AND g.locale = :language) AS hasDisplay
                FROM asset a LEFT JOIN day_stat d ON d.day = a.placement_day
                WHERE a.geo_cell IS NOT NULL AND a.category = 'camera' AND a.deleted_at IS NULL
                  AND (:hidden = 1 OR a.is_hidden = 0)
                GROUP BY a.geo_cell
                HAVING hasEn = 0 OR (:language != 'en' AND hasDisplay = 0)
                ORDER BY prio DESC, newest DESC, a.geo_cell
                LIMIT :limit
                """, arguments: ["language": language, "hidden": settings.includeHidden, "limit": limit]).compactMap { row in
                (row["cell"] as String?).flatMap(GeoCell.init(key:)).map {
                    Need(cell: $0, hasEnglish: (row["hasEn"] as Int) == 1, hasDisplay: (row["hasDisplay"] as Int) == 1)
                }
            }
        }
    }

    // MARK: Refresh

    /// FR-106 "Làm mới địa danh": forget every geocode; the next passes ask again and the folders,
    /// sidecars and views follow the new answers.
    func refreshAll() async throws {
        try await env.store.write { db in
            try db.execute(sql: "DELETE FROM geo_cache")
            try KeyValueRepository.set(db, Self.countryOnlyKey, nil)
            for day in try OrganizationQueries.promotedDays(db) { try DirtyQueue.mark(db, [.place], id: day.description) }
            try DirtyQueue.requestSweep(db, [.sidecar, .view, .description])
        }
        noProvinceStreak = 0
    }
}
