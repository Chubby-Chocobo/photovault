import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Placement allocation (spec 8.1): once the category is final the placement is fixed, before any
/// resource is exported. Name stems come from `NameStemBuilder`; collisions from the Store.
enum PlacementAllocator {
    /// Places `asset` if it has a final category and no placement yet. Returns the day whose
    /// `camera` count may have changed.
    static func place(_ db: Database, asset: AssetRecord, context: PipelineContext) throws -> (placement: Placement, day: ArchiveDay?)? {
        guard asset.placement == nil, let category = asset.category, !asset.categoryProvisional else { return nil }
        let resources = try ResourceRepository.fetchAll(db, key: asset.assetKey)
        let descriptors = resources.map(\.descriptor)
        let filename = ResourcePlanner.primary(of: descriptors)?.originalFilename ?? descriptors.first?.originalFilename ?? "unknown"
        let base = context.nameBuilder.baseStem(creationDate: asset.creationDate, primaryFilename: filename)
        let day: PlacementDay = asset.creationDate.map { .day(ArchiveDay(date: $0, timeZone: context.timeZone)) } ?? .unknown
        let placement = try AssetPlacementRepository.allocatePlacement(
            db, assetKey: asset.assetKey, baseStem: base, category: category, day: day, now: context.now)
        if category == .camera, let archiveDay = day.archiveDay, try DayPlaceRepository.exists(db, day: archiveDay) {
            let slot = try slotForLateArrival(db, asset: asset, day: archiveDay)
            if slot != nil { try AssetPlacementRepository.setPlaceSlot(db, key: asset.assetKey, slot: slot) }
        }
        return (placement, category == .camera ? day.archiveDay : nil)
    }

    /// A photo placed on a day that is already split has no file yet, so any slot costs nothing; `PlaceNamer`
    /// corrects a wrong guess later. The province of its cell decides when that is known, otherwise the
    /// photo nearest in time does (a tie goes to the earlier one). nil is the main folder.
    private static func slotForLateArrival(_ db: Database, asset: AssetRecord, day: ArchiveDay) throws -> String? {
        if let cell = asset.geoCell ?? asset.location.map(GeoCell.init),
           let english = try GeoCacheRepository.fetch(db, cell: cell, locale: "en")?.place,
           let key = PlaceNamingPolicy.identityKey(english) {
            if try DayStatRepository.fetch(db, day: day)?.placeKey == key { return nil }
            if let row = try DayPlaceRepository.fetchAll(db, day: day).first(where: { $0.placeKey == key }) { return row.slot }
        }
        guard let created = asset.creationDate else { return nil }
        let rows = try Row.fetchAll(db, sql: """
            SELECT place_slot, creation_date, asset_key FROM asset
            WHERE placement_category = 'camera' AND placement_day = ? AND deleted_at IS NULL
              AND asset_key != ? AND creation_date IS NOT NULL
            """, arguments: [day.description, asset.assetKey.rawValue])
        let nearest = rows.min { a, b in
            let da = abs((a["creation_date"] as Date).timeIntervalSince(created))
            let db = abs((b["creation_date"] as Date).timeIntervalSince(created))
            if da != db { return da < db }
            let (ta, tb) = (a["creation_date"] as Date, b["creation_date"] as Date)
            if ta != tb { return ta < tb }
            return (a["asset_key"] as String) < (b["asset_key"] as String)
        }
        return nearest?["place_slot"]
    }
}

/// Everything that follows a change to an asset row, in the same transaction: placement,
/// day counts and the destination set (FR-20 "recompute both ways").
enum AssetFinalizer {
    /// - Parameter dirtyDays: days whose `camera` count must be recounted by the caller once per
    ///   batch (a recount per asset would be quadratic during a scan).
    static func finalize(
        _ db: Database, key: AssetKey, context: PipelineContext, dirtyDays: inout Set<ArchiveDay>,
        extensions: [any JobPlanningExtension] = []
    ) throws {
        guard var asset = try AssetRepository.fetch(db, key: key), asset.deletedAt == nil else { return }
        if let creation = asset.creationDate, asset.category == .camera {
            dirtyDays.insert(ArchiveDay(date: creation, timeZone: context.timeZone))
        }
        if let placed = try PlacementAllocator.place(db, asset: asset, context: context) {
            asset.placement = placed.placement
            if let day = placed.day { dirtyDays.insert(day) }
        }
        try EligibilityService.recompute(db, asset: asset, context: context, extensions: extensions)
        // Sidecars, views and descriptions follow the asset only once something of it is at a destination.
        if try OrganizationQueries.hasDoneJob(db, key: key) { try DirtyQueue.mark(db, asset: key) }
    }

    /// Recounts the days and promotes those with a first camera asset; a promoted day is queued
    /// for place naming again because its asset set may have changed (FR-83).
    static func recount(_ db: Database, days: Set<ArchiveDay>, context: PipelineContext) throws {
        for day in days {
            try EngineQueries.recountDay(db, day: day, settings: context.settings)
            try DayFolderPromoter.promoteIfNeeded(db, day: day, context: context)
            if try DayStatRepository.fetch(db, day: day)?.promoted == true { try DirtyQueue.mark(db, [.place], id: day.description) }
        }
    }
}
