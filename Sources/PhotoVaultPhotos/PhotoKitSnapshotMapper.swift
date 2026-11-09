import Foundation
import Photos
import PhotoVaultCore

/// Maps `PHAsset` to `AssetSnapshot`.
struct PhotoKitSnapshotMapper: Sendable {
    let utiResolver: any UTIResolver

    func snapshot(of asset: PHAsset) -> AssetSnapshot {
        let resources = PHAssetResource.assetResources(for: asset).map { resource in
            ResourceDescriptor(
                type: ResourceType(rawValue: resource.type.rawValue),
                uti: resource.uniformTypeIdentifier,
                originalFilename: resource.originalFilename,
                isRaw: utiResolver.isRaw(resource.uniformTypeIdentifier)
            )
        }
        let burstId = asset.burstIdentifier
        let picks: PHAssetBurstSelectionType = [.autoPick, .userPick]
        let isPick = burstId == nil || asset.representsBurst || !asset.burstSelectionTypes.isDisjoint(with: picks)
        return AssetSnapshot(
            localId: asset.localIdentifier,
            mediaType: MediaType(rawValue: asset.mediaType.rawValue) ?? .unknown,
            subtypes: MediaSubtypes(rawValue: asset.mediaSubtypes.rawValue),
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.duration,
            isFavorite: asset.isFavorite,
            isHidden: asset.isHidden,
            burstIdentifier: burstId,
            burstIsPick: isPick,
            location: asset.location.map { GeoPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) },
            hasAdjustments: resources.contains { $0.type == .adjustmentData },
            resources: resources
        )
    }
}
