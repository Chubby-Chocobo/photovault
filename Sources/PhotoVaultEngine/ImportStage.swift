import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Machine reasons stored with an offline import (`source.status_reason`).
enum SourceStatusReason {
    static let unavailable = "unavailable"
    static let signInRequired = "signInRequired"
}

/// When each job was last held, so a folder that comes and goes cannot keep the cycle busy.
final class ImportHolds: @unchecked Sendable {
    /// A held job is not probed again before this much time has passed.
    static let backoff: TimeInterval = 30

    private let lock = NSLock()
    private var heldAt: [SourceID: Date] = [:]

    func mark(_ id: SourceID, at date: Date) { lock.withLock { heldAt[id] = date } }
    func isCoolingDown(_ id: SourceID, now: Date) -> Bool {
        lock.withLock { heldAt[id].map { now.timeIntervalSince($0) < Self.backoff } ?? false }
    }
}

/// Runs the folder imports inside the cycle (spec 8.4, after classification): lists a folder, reads and
/// hashes its files group by group outside any transaction, then ingests each group in one
/// transaction so a crash leaves either the whole group or nothing. Bounded work per run.
/// Listing is in `ImportStage+Listing`, reading and ingest in `ImportStage+Ingest`, completion in
/// `ImportStage+Completion`.
struct ImportStage: CycleStage {
    let env: EngineEnvironment
    let extensions: [any JobPlanningExtension]
    let holds = ImportHolds()
    var step: CycleStep { .classify }

    init(env: EngineEnvironment, extensions: [any JobPlanningExtension]) {
        self.env = env
        self.extensions = extensions
    }

    func run(trigger: SyncTrigger) async throws -> Bool {
        let open = try await env.store.read { db in
            try SourceRepository.fetchAll(db).filter { $0.kind.isImport && $0.status.isOpen }
        }
        var changed = false
        for source in open {
            try Task.checkCancellation()
            guard let folder = await env.sources.folder(for: source.id) else {
                // A cloud import whose token is gone has no adapter; only signing in again brings it back.
                if source.kind != .localFolder, source.status != .offline || source.statusReason != SourceStatusReason.signInRequired {
                    try await holdForSignIn(source.id)
                    changed = true
                }
                continue
            }
            if try await advance(source, folder) { changed = true }
        }
        return changed
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
            try await folder.probe()
            return true
        } catch SourceError.accessRevoked {
            if source.status != .offline || source.statusReason != SourceStatusReason.signInRequired { try await holdForSignIn(source.id) }
            return false
        } catch is SourceError {
            if source.status != .offline { try await hold(source.id) }
            return false
        }
    }

    /// A grant the provider no longer accepts: waiting does not help, so the job says so and stays held
    /// until the adapter answers again (the owner signed in).
    func holdForSignIn(_ id: SourceID) async throws {
        holds.mark(id, at: env.clock.now)
        try await setStatus(id, .offline, reason: SourceStatusReason.signInRequired)
        env.log.log(.notice, category: "import", "source access revoked; import held")
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
        guard try await reachable(source, folder) else { return true }
        if source.listedAt == nil { return try await list(source, folder) }
        return try await ingestBatch(source, folder)
    }
}
