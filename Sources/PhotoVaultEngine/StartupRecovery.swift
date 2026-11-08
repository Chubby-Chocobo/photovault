import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// Anything a later phase needs to resolve at startup (interrupted moves, renames, shortcuts,
/// replaceContent). Runs after the engine's own recovery.
public protocol RecoveryParticipant: Sendable {
    func recover() async throws
}

public struct RecoverySummary: Sendable, Equatable {
    public var exportsReset = 0
    public var jobsCompleted = 0
    public var jobsRequeued = 0
    public var jobsLeftForLater = 0
    public var foldersConfirmed = 0
    public var orphanFilesRemoved = 0
}

/// Spec 8.3 "Khởi động" and FR-44: every unfinished state is resolved before new work starts.
/// - resource `exporting` → `none`, orphan staging files removed;
/// - job `uploading` with a reserved id → probe: present with the expected hash → done; present
///   with other content → back to `pending` (the upload path replaces it in place); missing → back
///   to `pending` keeping the id and the session (the upload path resumes or opens a new one);
/// - job `uploading` at a path-addressed destination → probe the path saved with its intent: our
///   content there → done at that path (a changed layout or a newer edit is handled by the move
///   worker and a refresh); other content → foreign, the retry plans again; nothing there → retry;
/// - `remote_folder` rows with an unconfirmed reserved id → probe;
/// - move jobs in progress are left to the move worker (participants).
/// Idempotent: the cycle calls `resolveInterrupted` again while a destination was unreachable.
struct StartupRecovery: Sendable {
    let env: EngineEnvironment
    let staging: StagingManager
    var participants: [any RecoveryParticipant] = []

    func run() async throws -> RecoverySummary {
        var summary = RecoverySummary()
        summary.exportsReset = try await env.store.write { db in try ResourceRepository.resetExportingOnStartup(db) }
        summary.orphanFilesRemoved = try await staging.cleanupOrphans()
        let interrupted = try await resolveInterrupted()
        summary.jobsCompleted = interrupted.jobsCompleted
        summary.jobsRequeued = interrupted.jobsRequeued
        summary.jobsLeftForLater = interrupted.jobsLeftForLater
        summary.foldersConfirmed = interrupted.foldersConfirmed
        for participant in participants { try await participant.recover() }
        env.log.log(.info, category: "recovery", "startup recovery finished exports=\(summary.exportsReset) jobsRequeued=\(summary.jobsRequeued) jobsCompleted=\(summary.jobsCompleted)")
        return summary
    }

    /// Resolves jobs left `uploading` and unconfirmed folders. Safe to repeat.
    func resolveInterrupted() async throws -> RecoverySummary {
        var summary = RecoverySummary()
        let jobs = try await env.store.read { db in try JobRepository.fetch(db, state: .uploading) }
        for job in jobs {
            switch try await resolve(job) {
            case .completed: summary.jobsCompleted += 1
            case .requeued: summary.jobsRequeued += 1
            case .later: summary.jobsLeftForLater += 1
            }
        }
        for destination in try await env.store.read({ db in try DestinationRepository.fetchAll(db) }) {
            summary.foldersConfirmed += try await confirmFolders(of: destination)
        }
        return summary
    }

    private enum Resolution { case completed, requeued, later }

    private func resolve(_ job: UploadJob) async throws -> Resolution {
        let now = env.clock.now
        let identity = job.identity
        guard let destination = await env.destinations.destination(for: job.destinationId) else { return .later }
        // A reserved id (Drive) or the file the job already owns, else the path the interrupted
        // write was about to create (local / NAS, saved before the first byte).
        var intent: UploadIntent?
        if let jobId = job.id { intent = try await env.store.read { db in try UploadIntentRepository.fetch(db, jobId: jobId) } }
        guard let remoteId = job.remoteId ?? intent?.remotePath else {
            // Nothing was created without a reserved id (Drive): simply try again.
            try await requeue(identity)
            return .requeued
        }
        let item: RemoteItem?
        do {
            item = try await destination.probe(remoteId: remoteId)
        } catch let error as DestinationError {
            env.logJob(.notice, "recovery", jobId: job.id, "probe failed error=\(error); will retry")
            return .later
        }
        guard let item, !item.trashed else {
            try await requeue(identity)
            return .requeued
        }
        // Present with other content: not ours. Requeued; the retry plans again and, for an
        // original, takes a conflict name. Nothing is skipped for good because of it.
        let kind = destination.capabilities.verifiedHash
        let remoteHash: String?
        do {
            remoteHash = try await hash(of: item, kind: kind, destination: job.destinationId)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            env.logJob(.notice, "recovery", jobId: job.id, "hash of the file at the destination unreadable; will retry")
            return .later
        }
        let expected = try await expectedHashes(job, kind: kind, intent: intent)
        guard let remoteHash, expected.contains(remoteHash) else {
            try await requeue(identity)
            return .requeued
        }
        let layout = env.layout
        let remoteName = item.name
        try await env.store.write { db in
            var parent = ""
            if let asset = try AssetRepository.fetch(db, key: identity.assetKey), let placement = asset.placement {
                parent = LayoutResolver.parentLogical(try LayoutResolver.chain(db, placement: placement, layout: layout))
                // Where the file actually is: the folder whose id is the item's parent.
                if let actual = try RemoteFolderRepository.fetchAll(db, destinationId: identity.destinationId)
                    .first(where: { $0.remoteId != nil && item.parentIds.contains($0.remoteId!) }) {
                    parent = actual.logicalPath
                }
            }
            try UploadCompletion.commit(
                db, identity: identity, remoteId: item.remoteId, finalName: remoteName, uploadedParent: parent,
                verifiedHash: remoteHash, layout: layout, now: now)
        }
        env.logJob(.info, "recovery", jobId: job.id, "interrupted upload found complete at destination")
        return .completed
    }

    /// The hash a destination reports, or for a local folder (whose probe has none) the one the
    /// content reader computes. Nil when it cannot be told: the job is then planned again.
    private func hash(of item: RemoteItem, kind: ContentHashKind, destination: DestinationID) async throws -> String? {
        if let reported = kind == .md5 ? item.md5 : item.sha256 { return reported }
        guard kind == .sha256, item.kind == .file, let reader = env.localContent else { return nil }
        return try await reader.sha256(destination: destination, path: item.remoteId)
    }

    /// Hashes the interrupted upload may have left at the destination: the content the saved intent
    /// was writing (also when the asset was edited again since), the session's MD5 when a session
    /// was opened, and the hash of the staged generation if it is still the same.
    private func expectedHashes(_ job: UploadJob, kind: ContentHashKind, intent: UploadIntent?) async throws -> Set<String> {
        var hashes = Set<String>()
        if kind == .sha256, let intent { hashes.insert(intent.contentSha256) }
        if kind == .md5, let md5 = job.sessionMd5 { hashes.insert(md5) }
        let resource = try await env.store.read { db in try ResourceRepository.fetch(db, key: job.assetKey, type: job.resType) }
        if let resource, resource.stagingState == .ready, resource.stagingGen == job.uploadingGen,
           let hash = kind == .md5 ? resource.md5 : resource.sha256 {
            hashes.insert(hash)
        }
        return hashes
    }

    /// `uploading → pending`, keeping the reserved id and the session.
    private func requeue(_ identity: JobIdentity) async throws {
        let now = env.clock.now
        try await env.store.write { db in
            do {
                _ = try JobRepository.apply(db, .stagingLost, to: identity, now: now)
            } catch is JobTransitionError {
                // Already resolved by another path.
            }
        }
    }

    private func confirmFolders(of destination: DestinationRecord) async throws -> Int {
        guard destination.acceptsUploads, let dest = await env.destinations.destination(for: destination.id) else { return 0 }
        let id = destination.id
        let pending = try await env.store.read { db in
            try RemoteFolderRepository.fetchAll(db, destinationId: id).filter { !$0.created && $0.remoteId != nil }
        }
        var confirmed = 0
        for folder in pending {
            guard let remoteId = folder.remoteId else { continue }
            do {
                guard let item = try await dest.probe(remoteId: remoteId), item.kind == .folder, !item.trashed else { continue }
                var confirmedFolder = folder
                confirmedFolder.created = true
                let toSave = confirmedFolder
                try await env.store.write { db in try RemoteFolderRepository.save(db, toSave) }
                confirmed += 1
            } catch is DestinationError {
                continue
            }
        }
        return confirmed
    }
}
