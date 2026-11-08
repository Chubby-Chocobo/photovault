import Foundation

/// Scope and content eligibility per destination (spec 8.8). Pure.
public enum Eligibility {
    /// The asset entered the library after the destination's baseline.
    public static func inWindow(_ asset: AssetRecord, _ destination: DestinationRecord) -> Bool {
        guard let inserted = asset.insertedAt, let baseline = destination.baselineAt else { return false }
        return inserted >= baseline
    }

    public static func inScope(_ asset: AssetRecord, _ destination: DestinationRecord, archiveTimeZone: TimeZone) -> Bool {
        guard asset.deletedAt == nil else { return false }
        switch destination.scope {
        case .full:
            return true
        case .since(let day):
            if inWindow(asset, destination) { return true }
            guard let assetDay = asset.archiveDay(in: archiveTimeZone) else { return false }
            return assetDay >= day
        case .newOnly:
            return inWindow(asset, destination)
        }
    }

    /// Global ceiling switches that apply to the whole asset (FR-05, FR-19).
    public static func passesGlobalAssetSettings(_ asset: AssetRecord, _ settings: GlobalSettings) -> Bool {
        if asset.isHidden, !settings.includeHidden { return false }
        if asset.burstIdentifier != nil, !settings.includeAllBurstFrames, !asset.burstIsPick { return false }
        if asset.mediaType == .video, !settings.includeVideos { return false }
        return asset.mediaType == .image || asset.mediaType == .video
    }

    /// The asset may get jobs at this destination (resource selection is `ResourcePlanner`).
    public static func isEligible(_ asset: AssetRecord, _ destination: DestinationRecord, settings: GlobalSettings,
                                  archiveTimeZone: TimeZone) -> Bool {
        guard let category = asset.category, !asset.categoryProvisional else { return false }
        return passesGlobalAssetSettings(asset, settings)
            && destination.rules.categories.contains(category)
            && inScope(asset, destination, archiveTimeZone: archiveTimeZone)
    }

    /// A provisional asset must be classified when some destination could need it under
    /// `camera` or `saved` (FR-20).
    public static func needsClassification(_ asset: AssetRecord, destinations: [DestinationRecord], settings: GlobalSettings,
                                           archiveTimeZone: TimeZone) -> Bool {
        guard asset.categoryProvisional, passesGlobalAssetSettings(asset, settings) else { return false }
        return destinations.contains { dest in
            (dest.rules.categories.contains(.camera) || dest.rules.categories.contains(.saved))
                && inScope(asset, dest, archiveTimeZone: archiveTimeZone)
        }
    }
}
