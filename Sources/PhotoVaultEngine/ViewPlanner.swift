import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// The desired shortcut tree for a batch of assets at one destination, and what the `shortcut`
/// table holds for them (spec 8.13).
struct ViewPlan: Sendable {
    struct Slot: Hashable, Sendable {
        var view: ViewKind
        var assetKey: AssetKey
    }

    var desired: [DesiredShortcut] = []
    var current: [ShortcutRecord] = []
    var paths: [Slot: ViewPath] = [:]
    /// File name of each asset's target, used as the shortcut name.
    var names: [AssetKey: String] = [:]
}

enum ViewPlanner {
    static func enabledViews(_ settings: GlobalSettings) -> Set<ViewKind> {
        var views = Set<ViewKind>()
        if settings.viewByDeviceEnabled { views.insert(.byDevice) }
        if settings.viewByPlaceEnabled { views.insert(.byPlace) }
        if settings.viewFavoritesEnabled { views.insert(.favorites) }
        return views
    }

    static func context(_ db: Database, assets: [AssetRecord], settings: GlobalSettings) throws -> ViewContext {
        var byModel: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT make_model_key, group_id FROM device_model") {
            byModel[row["make_model_key"]] = row["group_id"]
        }
        var names: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT group_id, display_name FROM device_group") {
            names[row["group_id"]] = row["display_name"]
        }
        let cells = Set(assets.compactMap { $0.geoCell ?? $0.location.map(GeoCell.init) })
        let geocodes = try OrganizationLookups.geocodes(db, cells: cells, language: settings.placeNameLanguage)
        return ViewContext(
            deviceGroupByModelKey: byModel, deviceGroupNames: names, englishGeocodes: geocodes.english,
            displayGeocodes: settings.placeNamesEnabled ? geocodes.display : [:], includeHidden: settings.includeHidden)
    }

    static func plan(
        _ db: Database, keys: [AssetKey], destination: DestinationRecord, context: PipelineContext
    ) throws -> ViewPlan {
        let settings = context.settings
        let views = enabledViews(settings)
        let assets = try keys.compactMap { try AssetRepository.fetch(db, key: $0) }
        let viewContext = try Self.context(db, assets: assets, settings: settings)
        var plan = ViewPlan()
        for asset in assets {
            let resources = try ResourceRepository.fetchAll(db, key: asset.assetKey)
            let descriptors = resources.map(\.descriptor)
            let eligible = Eligibility.isEligible(asset, destination, settings: settings, archiveTimeZone: context.timeZone)
            let planned = eligible
                ? ResourcePlanner.plannedTypes(for: descriptors, mediaType: asset.mediaType, settings: settings, rules: destination.rules) : []
            var targetId: String?
            if let type = ResourcePlanner.viewTarget(of: descriptors, planned: planned),
               let job = try JobRepository.fetch(db, identity: JobIdentity(destinationId: destination.id, assetKey: asset.assetKey, resType: type)) {
                if job.state == .done { targetId = job.remoteId }
                plan.names[asset.assetKey] = job.remoteName
            }
            for view in views {
                if let path = ViewRules.path(for: asset, in: view, context: viewContext),
                   let parent = context.layout.viewFolderChain(path).last?.logicalPath {
                    plan.desired.append(DesiredShortcut(assetKey: asset.assetKey, view: view, parentLogical: parent, targetId: targetId))
                    plan.paths[.init(view: view, assetKey: asset.assetKey)] = path
                }
                if let record = try ShortcutRepository.fetch(db, destinationId: destination.id, view: view, assetKey: asset.assetKey) {
                    plan.current.append(record)
                }
            }
        }
        return plan
    }
}
