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
        let kind: TransferKind
        var account: String?
        if asset.sourceId == .photos { kind = .exportFromPhotos } else {
            let id = asset.sourceId
            let source = try await env.store.read { db in try SourceRepository.fetch(db, id: id) }
            kind = .download(source?.kind ?? .localFolder)
            account = source?.config.account
        }
        let transfer = env.transfers.begin(
            kind: kind, fileName: started.resource.originalFilename, accountEmail: account, sourceId: asset.sourceId, isBackfill: started.isBackfill,
            bytesTotal: started.resource.sizeBytes)
        defer { transfer.end() }
        started.permit.control.setProgress(transfer.sink)
        let file: ExportedFile
        do { file = try await content.exportResource(locator, to: url, control: started.permit.control) } catch {
            // An adapter reports `SourceError` only; anything else is a source that cannot be read now.
            // Photos keeps its own error type.
            if asset.sourceId == .photos || error is SourceError || error is CancellationError { throw error }
            env.log.log(.notice, category: "source", "source adapter failed unexpectedly")
            throw SourceError.unavailable
        }
        // The bytes must be the ones hashed at import (every file of the asset, not only the primary).
        if asset.sourceId != .photos {
            let expected = started.resource.sha256 ?? (started.isPrimary && asset.assetKey.isContent ? asset.assetKey.identifier : nil)
            if let expected, file.sha256 != expected { throw SourceError.fileChanged }
        }
        return file
    }

    /// How long an export waits when the folder of a finished import is away (an unplugged disk is
    /// usually plugged back in; nothing is lost by waiting).
    static let closedSourceRetry: TimeInterval = 3600

    /// How a folder error is handled. A folder that is away holds an open import (the import comes
    /// back by itself). For a finished or cancelled import the file is lost only when nothing can
    /// reopen it (its row is gone or, for a Mac folder, has no bookmark); otherwise the export waits, quietly, for the folder.
    func classifyFolderFailure(_ error: SourceError, asset: AssetRecord) async throws -> (errorClass: ErrorClass, retryDelay: TimeInterval) {
        let base = ErrorClassifier.classify(error)
        guard case .destinationLevel = base else { return (base, Self.transientRetryDelay) }
        let id = asset.sourceId
        let source = try await env.store.read { db in try SourceRepository.fetch(db, id: id) }
        if source?.status.isOpen == true { return (base, Self.transientRetryDelay) }
        guard let source, source.kind.isImport, source.kind != .localFolder || source.config.bookmark != nil else { return (.permanent(.resourceMissing), Self.transientRetryDelay) }
        // A cloud import with no valid grant waits for the owner to sign in again; the row says so.
        if source.kind != .localFolder {
            let adapterMissing = await env.sources.content(for: id) == nil
            if error == .accessRevoked || (error == .unavailable && adapterMissing) {
                try await markNeedsSignIn(id)
                // Every file of this source would ask the provider and fail the same way; ask again in an hour.
                let retryAt = env.clock.now.addingTimeInterval(Self.closedSourceRetry)
                try await env.store.write { db in try EngineQueries.deferExports(db, sourceId: id, until: retryAt) }
                signInDeferred.insert(id)
            }
        }
        return (base, Self.closedSourceRetry)
    }

    /// Records on a finished import that its files can be read again only after the owner signs in.
    private func markNeedsSignIn(_ id: SourceID) async throws {
        try await env.store.write { db in
            guard let row = try SourceRepository.fetch(db, id: id), !row.status.isOpen,
                  row.statusReason != SourceStatusReason.signInRequired else { return }
            try SourceRepository.setStatusReason(db, id: id, reason: SourceStatusReason.signInRequired)
        }
    }

    /// A folder that cannot be read holds only its own job: the source row goes `offline` (its assets
    /// leave the export candidates) and Photos exports carry on. The import stage brings it back.
    func holdSource(of asset: AssetRecord, at now: Date, reason: String = SourceStatusReason.unavailable) async throws {
        let id = asset.sourceId
        try await env.store.write { db in
            guard let source = try SourceRepository.fetch(db, id: id), source.status == .scanning || source.status == .importing else { return }
            try SourceRepository.setStatus(db, id: id, status: .offline, reason: reason, now: now)
        }
        env.log.log(.notice, category: "source", "source unavailable; holding its exports")
    }
}
