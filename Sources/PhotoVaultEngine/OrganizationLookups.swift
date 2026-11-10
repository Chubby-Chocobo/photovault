import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Reads that sidecars, descriptions and views share: device names and cached geocodes.
enum OrganizationLookups {
    static func deviceName(_ db: Database, asset: AssetRecord, resolver: DeviceNameResolver = .bundled) throws -> String? {
        guard let model = asset.cameraModel, !DeviceNameResolver.normalize(model).isEmpty else { return nil }
        let key = DeviceNameResolver.key(make: asset.cameraMake, model: model)
        let groupId = try DeviceGroupRepository.group(db, forMakeModelKey: key)?.groupId ?? DeviceNameResolver.groupId(forKey: key)
        if let group = try DeviceGroupRepository.group(db, id: groupId) { return group.displayName }
        return resolver.displayName(make: asset.cameraMake, model: model)
    }

    /// Names of the asset's cell under `PlaceNameRule`; nil when place names are off, the cell is not
    /// geocoded, or the asset is hidden while hidden assets are not uploaded.
    static func place(_ db: Database, asset: AssetRecord, settings: GlobalSettings) throws -> GeoPlace? {
        guard settings.placeNamesEnabled, settings.includeHidden || !asset.isHidden,
              let cell = asset.geoCell ?? asset.location.map(GeoCell.init) else { return nil }
        guard let english = try GeoCacheRepository.fetch(db, cell: cell, locale: "en")?.place else { return nil }
        // Wait for the second answer, so a file's metadata is not written once in English and again
        // in Vietnamese.
        guard let local = try GeoCacheRepository.fetch(db, cell: cell, locale: localLocaleKey)?.place else { return nil }
        return PlaceNameRule.display(english: english, local: local, withNative: false)
    }

    /// True while the asset's place would be named but a geocode answer for its cell is still missing.
    /// Only camera assets are geocoded (`GeocodeScheduler`), so any other asset never waits.
    static func placeIsPending(_ db: Database, asset: AssetRecord, settings: GlobalSettings) throws -> Bool {
        guard asset.category == .camera, asset.deletedAt == nil, settings.placeNamesEnabled, settings.includeHidden || !asset.isHidden,
              let cell = asset.geoCell ?? asset.location.map(GeoCell.init) else { return false }
        for locale in ["en", localLocaleKey] where try GeoCacheRepository.fetch(db, cell: cell, locale: locale) == nil { return true }
        return false
    }

    /// FR-43 description text for the files of `asset`.
    static func descriptionText(_ db: Database, asset: AssetRecord, settings: GlobalSettings) throws -> String? {
        DescriptionBuilder.text(asset: asset, deviceName: try deviceName(db, asset: asset), place: try place(db, asset: asset, settings: settings))
    }

    /// `geo_cache` locale under which a cell's answer in its second locale is kept, whatever that
    /// language is (`PlaceNameRule.secondLocale`).
    static let localLocaleKey = "local"

    /// The English and second-locale answers for the given cells.
    static func geocodes(_ db: Database, cells: Set<GeoCell>) throws -> (english: [GeoCell: GeoPlace], local: [GeoCell: GeoPlace]) {
        var english: [GeoCell: GeoPlace] = [:]
        var local: [GeoCell: GeoPlace] = [:]
        for cell in cells {
            if let entry = try GeoCacheRepository.fetch(db, cell: cell, locale: "en") { english[cell] = entry.place }
            if let entry = try GeoCacheRepository.fetch(db, cell: cell, locale: localLocaleKey) { local[cell] = entry.place }
        }
        return (english, local)
    }

    /// Names per cell under `PlaceNameRule`, for views.
    static func displayPlaces(english: [GeoCell: GeoPlace], local: [GeoCell: GeoPlace]) -> [GeoCell: GeoPlace] {
        english.reduce(into: [:]) { result, item in result[item.key] = PlaceNameRule.display(english: item.value, local: local[item.key]) }
    }
}

/// The last description written to a Drive file, so a refresh only touches files whose text changed.
enum DescriptionState {
    private static func key(_ destinationId: DestinationID, _ assetKey: AssetKey) -> String { "desc:\(destinationId.rawValue):\(assetKey.rawValue)" }

    static func record(_ db: Database, destinationId: DestinationID, key assetKey: AssetKey, text: String) throws {
        try KeyValueRepository.set(db, key(destinationId, assetKey), text)
    }

    static func recorded(_ db: Database, destinationId: DestinationID, key assetKey: AssetKey) throws -> String? {
        try KeyValueRepository.string(db, key(destinationId, assetKey))
    }
}

/// FR-43: `Camera: … · Lens: … · Place: …`; parts that are unknown are left out, nil when none is known.
enum DescriptionBuilder {
    static func text(asset: AssetRecord, deviceName: String?, place: GeoPlace?) -> String? {
        var parts: [String] = []
        if let deviceName, !deviceName.isEmpty { parts.append("Camera: \(deviceName)") }
        if let lens = asset.lensModel?.trimmingCharacters(in: .whitespaces), !lens.isEmpty { parts.append("Lens: \(lens)") }
        if let place {
            var names: [String] = []
            for name in [place.locality, place.administrativeArea, place.country] {
                if let name, !name.isEmpty, !names.contains(name) { names.append(name) }
            }
            if !names.isEmpty { parts.append("Place: " + names.joined(separator: ", ")) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
