import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// Sidecar jobs have no resource and no PhotoKit export: the file is generated here, written to
/// staging for the upload and removed afterwards (FR-90).
extension UploadAttempt {
    func performSidecar() async throws -> UploadOutcome {
        let snapshot = await env.settingsSnapshot()
        let builder = env.nameBuilder(snapshot.timeZone)
        let layout = env.layout
        let id = identity
        let kind = record.kind
        let built: (file: SidecarFile, plan: UploadPlan)? = try await env.store.read { db in
            guard let asset = try AssetRepository.fetch(db, key: id.assetKey), let placement = asset.placement,
                  let file = try SidecarFactory.build(
                    db, asset: asset, destinationId: id.destinationId, type: id.resType, settings: snapshot.settings,
                    timeZone: snapshot.timeZone, nameBuilder: builder) else { return nil }
            let chain = try LayoutResolver.chain(db, placement: placement, layout: layout)
            return (file, UploadPlan(
                asset: asset, chain: chain, parentLogical: LayoutResolver.parentLogical(chain),
                fileName: NameStemBuilder.sidecarName(stem: placement.nameStem, type: id.resType),
                properties: AppPropertyCodec.fileProperties(assetKey: id.assetKey, resType: id.resType, category: placement.category)))
        }
        guard let built else { return .unsupported }
        let hash = SidecarFactory.hash(built.file, kind: kind)
        if try await destinationAlreadyHolds(hash) { return try await finishWithoutUpload(hash: hash, plan: built.plan) }

        let url = staging.fileURL(assetKey: id.assetKey, type: id.resType, generation: ready.job.targetGen)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try built.file.data.write(to: url, options: .atomic)
        let content = StagedContent(file: url, size: Int64(built.file.data.count), md5: built.file.md5, sha256: built.file.sha256)
        await staging.lease(url.path)
        let outcome: UploadOutcome
        do {
            outcome = try await transfer(generation: ready.job.targetGen, plan: built.plan, description: nil, content: content)
        } catch {
            await staging.unlease(url.path)
            staging.remove(url)
            throw error
        }
        await staging.unlease(url.path)
        staging.remove(url)
        return outcome
    }

    /// The recorded hash matches, or the file at the destination already carries the new content
    /// (a replace that finished just before a crash).
    private func destinationAlreadyHolds(_ hash: String) async throws -> Bool {
        let job = ready.job
        guard let remoteId = job.remoteId, job.doneGen > 0 else { return false }
        if job.uploadedHash == hash { return true }
        guard let item = try await destination.probe(remoteId: remoteId), !item.trashed else { return false }
        return (hashKind == .md5 ? item.md5 : item.sha256) == hash
    }

    private func finishWithoutUpload(hash: String, plan: UploadPlan) async throws -> UploadOutcome {
        let job = ready.job
        guard let remoteId = job.remoteId else { return .unsupported }
        _ = try await apply(.startUpload(generation: job.targetGen))
        let now = env.clock.now
        let layout = env.layout
        let id = identity
        let parent = job.remoteLogicalParent ?? plan.parentLogical
        let name = job.remoteName ?? plan.fileName
        _ = try await env.store.write { db in
            try UploadCompletion.commit(
                db, identity: id, remoteId: remoteId, finalName: name, uploadedParent: parent, verifiedHash: hash, layout: layout, now: now)
        }
        return .done(bytes: 0)
    }
}
