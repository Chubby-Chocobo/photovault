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
        // The bytes must be the ones hashed at import (every file of the asset, not only the primary).
        if asset.sourceId != .photos {
            let expected = started.resource.sha256 ?? (started.isPrimary && asset.assetKey.isContent ? asset.assetKey.identifier : nil)
            if let expected, file.sha256 != expected { throw SourceError.fileChanged }
        }
        return file
    }

    /// How a folder error is handled. A folder that is away holds an open import; for an import that has
    /// finished (or whose row is gone) nobody is waiting for the folder, so the file counts as missing.
    func classifyFolderFailure(_ error: SourceError, asset: AssetRecord) async throws -> ErrorClass {
        let base = ErrorClassifier.classify(error)
        guard case .destinationLevel = base else { return base }
        let id = asset.sourceId
        let status = try await env.store.read { db in try SourceRepository.fetch(db, id: id)?.status }
        return status?.isOpen == true ? base : .permanent(.resourceMissing)
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
