import Foundation

/// Lookup data the view rules read; built by the engine from the store.
public struct ViewContext: Sendable {
    /// `device_model`: normalized `make|model` key to group id.
    public var deviceGroupByModelKey: [String: String]
    /// `device_group`: group id to owner-visible name.
    public var deviceGroupNames: [String: String]
    public var deviceNames: DeviceNameResolver
    public var englishGeocodes: [GeoCell: GeoPlace]
    public var displayGeocodes: [GeoCell: GeoPlace]
    /// "Hidden upload" setting.
    public var includeHidden: Bool

    public init(
        deviceGroupByModelKey: [String: String] = [:], deviceGroupNames: [String: String] = [:],
        deviceNames: DeviceNameResolver = .bundled, englishGeocodes: [GeoCell: GeoPlace] = [:],
        displayGeocodes: [GeoCell: GeoPlace] = [:], includeHidden: Bool = false
    ) {
        self.deviceGroupByModelKey = deviceGroupByModelKey
        self.deviceGroupNames = deviceGroupNames
        self.deviceNames = deviceNames
        self.englishGeocodes = englishGeocodes
        self.displayGeocodes = displayGeocodes
        self.includeHidden = includeHidden
    }
}

/// Membership and location of an asset in each Drive view (FR-104..106).
public enum ViewRules {
    /// Views the asset belongs to, with its folder path in each. Assets without a placement day
    /// belong to none.
    public static func paths(for asset: AssetRecord, context: ViewContext) -> [ViewPath] {
        ViewKind.allCases.compactMap { path(for: asset, in: $0, context: context) }
    }

    public static func path(for asset: AssetRecord, in view: ViewKind, context: ViewContext) -> ViewPath? {
        guard let day = asset.placement?.day.archiveDay else { return nil }
        switch view {
        case .favorites:
            return asset.isFavorite ? .favorites(day: day) : nil
        case .byDevice:
            return devicePath(asset, day: day, context: context)
        case .byPlace:
            return placePath(asset, day: day, context: context)
        }
    }

    private static func devicePath(_ asset: AssetRecord, day: ArchiveDay, context: ViewContext) -> ViewPath? {
        guard asset.placement?.category == .camera, let model = asset.cameraModel,
              !DeviceNameResolver.normalize(model).isEmpty else { return nil }
        let key = DeviceNameResolver.key(make: asset.cameraMake, model: model)
        let groupId = context.deviceGroupByModelKey[key] ?? DeviceNameResolver.groupId(forKey: key)
        let name = context.deviceGroupNames[groupId] ?? context.deviceNames.displayName(make: asset.cameraMake, model: model)
        return .byDevice(groupKey: groupId, groupName: name, day: day)
    }

    private static func placePath(_ asset: AssetRecord, day: ArchiveDay, context: ViewContext) -> ViewPath? {
        guard asset.placement?.category == .camera, asset.deletedAt == nil,
              context.includeHidden || !asset.isHidden,
              let cell = asset.geoCell ?? asset.location.map(GeoCell.init),
              let english = context.englishGeocodes[cell],
              let identity = PlaceNamingPolicy.identity(english) else { return nil }
        let display = context.displayGeocodes[cell] ?? english
        let countryName = display.country ?? english.country ?? identity.iso
        let areaName = display.administrativeArea ?? identity.area
        return .byPlace(
            countryKey: NameSanitizer.sanitize(identity.iso), countryName: countryName,
            areaKey: NameSanitizer.sanitize(identity.area), areaName: areaName, day: day
        )
    }
}
