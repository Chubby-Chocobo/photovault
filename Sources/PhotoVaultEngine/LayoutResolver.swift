import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Where and under which name a job's file goes, computed from the placement and the current
/// `day_stat` inside a transaction (spec 8.4 step 6).
struct UploadPlan: Sendable {
    var asset: AssetRecord
    var chain: [FolderLevel]
    var parentLogical: String
    var fileName: String
    var properties: [String: String]
}

enum LayoutResolver {
    /// The folders for an asset's files. A camera asset with a slot goes to the extra folder of its day;
    /// every other asset (and a camera asset without a slot) goes to the main folder.
    static func chain(_ db: Database, asset: AssetRecord, layout: any LayoutPolicy) throws -> [FolderLevel] {
        guard let placement = asset.placement else { return [] }
        var placeName: String?
        if placement.category == .camera, let day = placement.day.archiveDay {
            if let slot = asset.placeSlot {
                let name = try DayPlaceRepository.fetchAll(db, day: day).first { $0.slot == slot }?.placeName
                return layout.folderChain(for: placement, placeName: name, slot: slot)
            }
            // A day that is waiting for its geocodes keeps the name it was given, so a folder created
            // meanwhile is not left with the bare date.
            if let stat = try DayStatRepository.fetch(db, day: day), stat.placeState == .named || stat.placeState == .waitingGeocode {
                placeName = stat.placeName
            }
        }
        return layout.folderChain(for: placement, placeName: placeName, slot: nil)
    }

    static func parentLogical(_ chain: [FolderLevel]) -> String { chain.last?.logicalPath ?? "" }

    static func plan(
        _ db: Database, job: UploadJob, resource: ResourceRecord, layout: any LayoutPolicy, nameBuilder: NameStemBuilder
    ) throws -> UploadPlan? {
        guard let asset = try AssetRepository.fetch(db, key: job.assetKey), let placement = asset.placement else { return nil }
        let chain = try chain(db, asset: asset, layout: layout)
        return UploadPlan(
            asset: asset, chain: chain, parentLogical: parentLogical(chain),
            fileName: nameBuilder.fileName(stem: placement.nameStem, resource: resource),
            properties: AppPropertyCodec.fileProperties(assetKey: job.assetKey, resType: job.resType, category: placement.category))
    }
}

/// The `uploading → done` transaction: the job is finished and, in the same transaction, its parent
/// is compared with the layout as it is now. A placement that changed while the file was in flight
/// (a new archive day after an edit, a root change) leaves the file in the old folder, so a
/// `move_job` is created.
enum UploadCompletion {
    @discardableResult
    static func commit(
        _ db: Database, identity: JobIdentity, remoteId: String, finalName: String, uploadedParent: String,
        verifiedHash: String, layout: any LayoutPolicy, description: String? = nil, now: Date
    ) throws -> UploadJob {
        let job = try JobRepository.apply(
            db, .uploadSucceeded(remoteId: remoteId, finalName: finalName, parent: uploadedParent, verifiedHash: verifiedHash),
            to: identity, now: now)
        if let jobId = job.id { try UploadIntentRepository.delete(db, jobId: jobId) }
        if let asset = try AssetRepository.fetch(db, key: identity.assetKey), asset.placement != nil {
            let current = LayoutResolver.parentLogical(try LayoutResolver.chain(db, asset: asset, layout: layout))
            try MoveJobPlanner.enqueueMove(db, identity: identity, from: uploadedParent, to: current, now: now)
        }
        try DestinationRepository.markSuccess(db, id: identity.destinationId, at: now)
        try ResourceRepository.touch(db, key: identity.assetKey, type: identity.resType, now: now)
        if !identity.resType.isSidecar {
            try DirtyQueue.mark(db, asset: identity.assetKey)
            if let description { try DescriptionState.record(db, destinationId: identity.destinationId, key: identity.assetKey, text: description) }
        }
        return job
    }
}
