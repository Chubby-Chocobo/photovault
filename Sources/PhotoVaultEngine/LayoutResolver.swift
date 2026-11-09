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
    static func chain(_ db: Database, placement: Placement, layout: any LayoutPolicy) throws -> [FolderLevel] {
        var placeName: String?
        if placement.category == .camera, let day = placement.day.archiveDay, let stat = try DayStatRepository.fetch(db, day: day) {
            placeName = stat.placeState == .named ? stat.placeName : nil
        }
        return layout.folderChain(for: placement, placeName: placeName)
    }

    static func parentLogical(_ chain: [FolderLevel]) -> String { chain.last?.logicalPath ?? "" }

    static func plan(
        _ db: Database, job: UploadJob, resource: ResourceRecord, layout: any LayoutPolicy, nameBuilder: NameStemBuilder
    ) throws -> UploadPlan? {
        guard let asset = try AssetRepository.fetch(db, key: job.assetKey), let placement = asset.placement else { return nil }
        let chain = try chain(db, placement: placement, layout: layout)
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
        if let asset = try AssetRepository.fetch(db, key: identity.assetKey), let placement = asset.placement {
            let current = LayoutResolver.parentLogical(try LayoutResolver.chain(db, placement: placement, layout: layout))
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
