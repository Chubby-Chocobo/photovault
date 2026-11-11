import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Runs the folder imports inside the cycle (spec 8.4, after classification): lists a folder, reads and
/// hashes its files group by group outside any transaction, then ingests each group in one
/// transaction so a crash leaves either the whole group or nothing. Bounded work per run.
/// Listing is in `ImportStage+Listing`, reading and ingest in `ImportStage+Ingest`, completion in
/// `ImportStage+Completion`.
struct ImportStage: CycleStage {
    let env: EngineEnvironment
    let extensions: [any JobPlanningExtension]
    let holds: ImportHolds
    let interrupts: ImportInterrupts
    /// True while an owner command waits for the lane.
    let commandWaiting: @Sendable () async -> Bool
    var step: CycleStep { .classify }

    init(
        env: EngineEnvironment, extensions: [any JobPlanningExtension], holds: ImportHolds = ImportHolds(),
        interrupts: ImportInterrupts = ImportInterrupts(), commandWaiting: @escaping @Sendable () async -> Bool = { false }
    ) {
        self.env = env
        self.extensions = extensions
        self.holds = holds
        self.interrupts = interrupts
        self.commandWaiting = commandWaiting
    }

    /// The pass should end after the file in hand: the owner paused, or a command waits for the lane.
    func shouldYield() async -> Bool { interrupts.paused ? true : await commandWaiting() }

    func run(trigger: SyncTrigger) async throws -> Bool {
        let open = try await env.store.read { db in
            try SourceRepository.fetchAll(db).filter { $0.kind.isImport && $0.status.isOpen }
        }
        var changed = false
        for source in open {
            try Task.checkCancellation()
            // A cancel the owner asked for (now, or stored before a relaunch): read nothing more. Its bookkeeping takes jobs out
            // of the plan, so it waits for the start of the next round, where no upload runs (`ImportCancellation.settleRequested`),
            // or for the owner's command at the pass boundary. Reporting work makes the cycle run that round.
            if cancelRequested(source) {
                changed = true
                continue
            }
            guard let folder = await env.sources.folder(for: source.id) else {
                // A cloud import whose token is gone has no adapter; only signing in again brings it back.
                if source.kind != .localFolder, source.status != .offline || source.statusReason != SourceStatusReason.signInRequired {
                    try await holdForSignIn(source.id)
                    changed = true
                }
                continue
            }
            if try await advance(source, folder) { changed = true }
            // A cancel that came during the pass: the exporter skips the groups this pass committed, and the next round ends the job.
            if interrupts.isCancelRequested(source.id) { changed = true }
        }
        return changed
    }

    private func cancelRequested(_ source: SourceRecord) -> Bool {
        interrupts.isCancelRequested(source.id) || source.config.cancelRequested == true
    }

    private func advance(_ source: SourceRecord, _ folder: any FolderImportSource) async throws -> Bool {
        switch source.status {
        case .offline: return try await resume(source, folder)
        case .scanning: return try await scan(source, folder)
        case .importing: return try await finishWhenDone(source)
        case .completed, .cancelled: return false
        }
    }

    // MARK: Availability

    /// An unreachable folder holds its own job only; it picks up again when the folder is back. Files
    /// still waiting to be read send the job back to reading, not to the upload wait.
    private func resume(_ source: SourceRecord, _ folder: any FolderImportSource) async throws -> Bool {
        guard !holds.isCoolingDown(source.id, now: env.clock.now) else { return false }
        guard try await reachable(source, folder) else { return false }
        let id = source.id
        let pending = try await env.store.read { db in try ImportItemRepository.counts(db, sourceId: id)[.pending] ?? 0 }
        let status: SourceStatus = source.listedAt == nil || pending > 0 ? .scanning : .importing
        try await setStatus(id, status, reason: nil)
        return true
    }

    /// False when the folder cannot be read now; the job is then marked offline.
    func reachable(_ source: SourceRecord, _ folder: any FolderImportSource) async throws -> Bool {
        do {
            try await adapter { try await folder.probe() }
            return true
        } catch SourceError.accessRevoked {
            if source.status != .offline || source.statusReason != SourceStatusReason.signInRequired {
                try await holdForSignIn(source.id)
            } else {
                holds.mark(source.id, at: env.clock.now, wait: ImportHolds.signInBackoff)
            }
            return false
        } catch SourceError.busy {
            pauseBriefly(source.id)
            return false
        } catch is SourceError {
            try await holdUnreachable(source)
            return false
        } catch is AdapterFault {
            try await holdUnreachable(source)
            return false
        }
    }

    /// Runs an adapter call. Anything it throws other than a `SourceError` or a cancellation counts as
    /// "the source cannot be read now", so one misbehaving adapter cannot stop the other jobs or Photos.
    func adapter<T>(_ call: () async throws -> T) async throws -> T {
        do { return try await call() } catch let error as SourceError { throw error } catch is CancellationError { throw CancellationError() } catch {
            env.log.log(.notice, category: "import", "source adapter failed unexpectedly")
            throw AdapterFault()
        }
    }

    /// An adapter threw something that is not a `SourceError`; the job is held like an unreachable source.
    struct AdapterFault: Error {}

    /// The provider is throttling or short of room here: the job keeps its place and tries again after the
    /// cooldown. It is not marked offline, because nothing is wrong with the source.
    func pauseBriefly(_ id: SourceID) {
        holds.mark(id, at: env.clock.now)
        env.log.log(.info, category: "import", "source busy; import pauses briefly")
    }

    /// A grant the provider no longer accepts: waiting does not help, so the job says so and stays held
    /// until the adapter answers again (the owner signed in).
    func holdForSignIn(_ id: SourceID) async throws {
        holds.mark(id, at: env.clock.now, wait: ImportHolds.signInBackoff)
        try await setStatus(id, .offline, reason: SourceStatusReason.signInRequired)
        env.log.log(.notice, category: "import", "source access revoked; import held")
    }

    /// An unreachable source is marked offline once; later failed probes only renew the cooldown.
    private func holdUnreachable(_ source: SourceRecord) async throws {
        if source.status != .offline { try await hold(source.id) } else { holds.mark(source.id, at: env.clock.now) }
    }

    func hold(_ id: SourceID) async throws {
        holds.mark(id, at: env.clock.now)
        try await setStatus(id, .offline, reason: SourceStatusReason.unavailable)
        env.log.log(.notice, category: "import", "source unavailable; import held")
    }

    func setStatus(_ id: SourceID, _ status: SourceStatus, reason: String?) async throws {
        let now = env.clock.now
        try await env.store.write { db in
            // A cancel that landed meanwhile stays cancelled.
            guard let current = try SourceRepository.fetch(db, id: id)?.status, current.isOpen else { return }
            try SourceRepository.setStatus(db, id: id, status: status, reason: reason, now: now)
        }
    }

    private func scan(_ source: SourceRecord, _ folder: any FolderImportSource) async throws -> Bool {
        guard !holds.isCoolingDown(source.id, now: env.clock.now) else { return false }
        guard try await reachable(source, folder) else { return true }
        if source.listedAt == nil { return try await list(source, folder) }
        return try await ingestBatch(source, folder)
    }
}
