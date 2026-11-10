import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Step 9 of the cycle (FR-80..85, spec 8.11): names promoted day folders from cached geocodes.
/// Everything here is database work; the network part is `GeocodeScheduler`. A day is evaluated when
/// it was promoted, its asset set changed, a geocode for one of its cells arrived, or while it is
/// still `pending` (the six-hour wait after the day ended is time-based).
struct PlaceNamer: Sendable {
    let env: EngineEnvironment

    /// Evaluates the days that need it; returns how many changed their state or name.
    func runPass() async throws -> Int {
        let snapshot = await env.settingsSnapshot()
        guard snapshot.settings.placeNamesEnabled else { return 0 }
        var changed = 0
        var seen = Set<String>()
        let hiddenBasis = snapshot.settings.includeHidden ? "1" : "0"
        try await env.store.write { db in try Self.markDaysForUpgrade(db, hiddenBasis: hiddenBasis) }
        while true {
            try Task.checkCancellation()
            let env = env
            let already = seen
            let (days, count): ([String], Int) = try await env.store.write { db in
                let dirty = try DirtyQueue.pending(db, .place, limit: 100)
                // Days waiting for a geocode come back through the dirty queue when an answer for one
                // of their cells arrives; only the time-based wait is polled here.
                let waiting = try String.fetchAll(db, sql: """
                    SELECT day FROM day_stat WHERE promoted = 1 AND place_state = 'pending' ORDER BY day
                    """)
                // At most 100 days per transaction: every camera day is promoted, so a first sync has thousands.
                let todo = Array(Array(Set(dirty + waiting).subtracting(already)).sorted().prefix(100))
                let context = try env.context(db, snapshot)
                var count = 0
                var retry: [String] = []
                for text in todo {
                    guard let day = ArchiveDay(string: text) else { continue }
                    let outcome = try Self.evaluateDay(db, day: day, context: context)
                    if outcome.changed { count += 1 }
                    if outcome.needsRetry { retry.append(text) }
                }
                // A dirty day not evaluated now (already seen in this pass, or past the batch) keeps its mark.
                try DirtyQueue.clear(db, .place, ids: dirty.filter(todo.contains))
                // A group waiting for a folder name to be freed is placed by the next evaluation.
                for text in retry { try DirtyQueue.mark(db, [.place], id: text) }
                return (todo, count)
            }
            if days.isEmpty { return changed }
            seen.formUnion(days)
            changed += count
        }
    }

    /// Days are split from this release on, and the grouping depends on the hidden-upload setting:
    /// evaluate every promoted day once after the upgrade and once per change of that setting.
    private static func markDaysForUpgrade(_ db: Database, hiddenBasis: String) throws {
        let upgraded = try KeyValueRepository.int(db, "place_split_backfill") == 1
        let basisChanged = try KeyValueRepository.string(db, "place_hidden_basis") != hiddenBasis
        guard !upgraded || basisChanged else { return }
        for day in try OrganizationQueries.promotedDays(db) { try DirtyQueue.mark(db, [.place], id: day.description) }
        try KeyValueRepository.set(db, "place_split_backfill", 1)
        try KeyValueRepository.set(db, "place_hidden_basis", hiddenBasis)
    }

    /// Evaluates one promoted day inside the caller's transaction. Returns true when something changed.
    static func evaluate(_ db: Database, day: ArchiveDay, context: PipelineContext) throws -> Bool {
        try evaluateDay(db, day: day, context: context).changed
    }

    /// A day is split by province unless the geocoder is in its country-only fallback: then a split
    /// day is left exactly as it is, and any other day is named by the single-place rule.
    static func evaluateDay(_ db: Database, day: ArchiveDay, context: PipelineContext) throws -> DaySplitWriter.Outcome {
        var outcome = DaySplitWriter.Outcome()
        guard let stat = try DayStatRepository.fetch(db, day: day), stat.promoted else { return outcome }
        let countryOnly = try KeyValueRepository.int(db, GeocodeScheduler.countryOnlyKey) == 1
        if countryOnly, try DayPlaceRepository.exists(db, day: day) { return outcome }

        let settings = context.settings
        var assets: [PlaceAsset] = []
        var cells = Set<GeoCell>()
        for key in try OrganizationQueries.cameraAssetKeys(db, day: day) {
            guard let asset = try AssetRepository.fetch(db, key: key) else { continue }
            assets.append(PlaceAsset(
                location: asset.location, isHidden: asset.isHidden, isDeleted: asset.deletedAt != nil,
                id: key.rawValue, creationDate: asset.creationDate))
            if let point = asset.location { cells.insert(GeoCell(point)) }
        }
        let geocodes = try OrganizationLookups.geocodes(db, cells: cells)
        let input = PlaceNamingInput(
            assets: assets, includeHidden: settings.includeHidden, englishGeocodes: geocodes.english,
            localGeocodes: geocodes.local, homeCountryCode: settings.homeCountryCode, day: day, archiveTimeZone: context.timeZone, now: context.now)

        let result: PlaceSplitResult
        if countryOnly {
            let single = PlaceNamingPolicy.evaluate(input)
            switch single.state {
            case .pending: result = .pending
            case .waitingGeocode: result = .waitingGeocode(single.cellsToGeocode)
            case .named, .unnamed:
                let live = assets.filter { !$0.isDeleted }.map(\.id).sorted()
                result = .groups([PlaceGroup(key: single.placeKey, name: single.state == .named ? single.placeName : nil, state: single.state, members: live)], unassigned: [])
            }
        } else {
            result = PlaceSplitPolicy.evaluate(input)
        }

        switch result {
        case .pending:
            return outcome
        case .waitingGeocode:
            guard stat.placeState != .waitingGeocode else { return outcome }
            try DayStatRepository.setPlace(db, day: day, state: .waitingGeocode, key: stat.placeKey, name: stat.placeName)
            outcome.changed = true
            return outcome
        case .groups(let groups, let unassigned):
            return try DaySplitWriter.apply(db, day: day, groups: groups, unassigned: unassigned, stat: stat, context: context)
        }
    }
}
