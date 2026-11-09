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
                for text in todo {
                    guard let day = ArchiveDay(string: text) else { continue }
                    if try Self.evaluate(db, day: day, context: context) { count += 1 }
                }
                // A dirty day not evaluated now (already seen in this pass, or past the batch) keeps its mark.
                try DirtyQueue.clear(db, .place, ids: dirty.filter(todo.contains))
                return (todo, count)
            }
            if days.isEmpty { return changed }
            seen.formUnion(days)
            changed += count
        }
    }

    /// Evaluates one promoted day inside the caller's transaction. Returns true when something changed.
    static func evaluate(_ db: Database, day: ArchiveDay, context: PipelineContext) throws -> Bool {
        guard let stat = try DayStatRepository.fetch(db, day: day), stat.promoted else { return false }
        let settings = context.settings
        var assets: [PlaceAsset] = []
        var cells = Set<GeoCell>()
        for key in try OrganizationQueries.cameraAssetKeys(db, day: day) {
            guard let asset = try AssetRepository.fetch(db, key: key) else { continue }
            assets.append(PlaceAsset(location: asset.location, isHidden: asset.isHidden, isDeleted: asset.deletedAt != nil))
            if let point = asset.location { cells.insert(GeoCell(point)) }
        }
        let geocodes = try OrganizationLookups.geocodes(db, cells: cells)
        let result = PlaceNamingPolicy.evaluate(PlaceNamingInput(
            assets: assets, includeHidden: settings.includeHidden, englishGeocodes: geocodes.english,
            localGeocodes: geocodes.local, homeCountryCode: settings.homeCountryCode, day: day, archiveTimeZone: context.timeZone, now: context.now))
        switch result.state {
        case .pending:
            return false
        case .waitingGeocode:
            guard stat.placeState != .waitingGeocode else { return false }
            try DayStatRepository.setPlace(db, day: day, state: .waitingGeocode, key: stat.placeKey, name: stat.placeName)
            return true
        case .named, .unnamed:
            let name = result.state == .named ? result.placeName : nil
            let renamed = name != stat.placeName
            guard renamed || stat.placeState != result.state else { return false }
            try DayStatRepository.setPlace(db, day: day, state: result.state, key: result.placeKey, name: name)
            if renamed { try applyRename(db, day: day, name: name, context: context) }
            return true
        }
    }

    /// The folder name changed: rename it at every destination, refresh what mentions the place.
    private static func applyRename(_ db: Database, day: ArchiveDay, name: String?, context: PipelineContext) throws {
        let placement = Placement(category: .camera, day: .day(day), nameStem: "")
        guard let level = context.layout.folderChain(for: placement, placeName: name).last else { return }
        for destination in context.destinations {
            try MoveJobPlanner.enqueueRename(
                db, destinationId: destination.id, logicalPath: level.logicalPath, to: level.displayName, now: context.now)
        }
        for key in try OrganizationQueries.cameraAssetKeys(db, day: day) { try DirtyQueue.mark(db, asset: key) }
    }
}
