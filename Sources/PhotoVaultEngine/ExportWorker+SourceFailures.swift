import Foundation
import PhotoVaultCore
import PhotoVaultStore

extension ExportWorker {
    /// Streams one resource from the source its asset came from. A source that is not registered
    /// (its folder was never reopened) cannot be read now.
    func readResource(_ started: Started, to url: URL) async throws -> ExportedFile {
        let asset = started.asset
        guard let content = await env.sources.content(for: asset.sourceId) else { throw SourceError.unavailable }
        let locator = ResourceLocator(
            sourceId: asset.sourceId, localId: asset.localId, type: started.resource.type,
            originalFilename: started.resource.originalFilename)
        let file = try await content.exportResource(locator, to: url, control: started.permit.control)
        // An imported asset is named by the hash of its primary file: other bytes mean the file changed since.
        if asset.assetKey.isContent, started.isPrimary, file.sha256 != asset.assetKey.identifier { throw SourceError.fileChanged }
        return file
    }

    /// A folder that cannot be read holds only its own job: the source row goes `offline` (its assets
    /// leave the export candidates) and Photos exports carry on. The import stage brings it back.
    func holdSource(of asset: AssetRecord, at now: Date) async throws {
        let id = asset.sourceId
        try await env.store.write { db in
            guard let source = try SourceRepository.fetch(db, id: id), source.status == .scanning || source.status == .importing else { return }
            try SourceRepository.setStatus(db, id: id, status: .offline, reason: "unavailable", now: now)
        }
        env.log.log(.notice, category: "source", "source unavailable; holding its exports")
    }
}
