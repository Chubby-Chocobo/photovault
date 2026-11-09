import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// FR-47 (Drive) and FR-76 (local): compares what the database says is at a destination with what
/// is really there. Files that are gone become `missingRemote` and are counted; nothing is
/// uploaded again until the owner confirms (`confirmReupload`, T20). Nothing at a destination is
/// ever deleted; the only thing trashed is a stray shortcut of the app's own views.
struct IntegrityChecker: Sendable {
    static let lastRunKey = "integrity_last:"
    /// The latest result per destination: files gone, files that differ, and when it was made.
    static let resultMissingKey = "integrity_result_missing:"
    static let resultMismatchKey = "integrity_result_mismatch:"
    static let resultAtKey = "integrity_result_at:"
    /// Set when the owner dismissed the mismatch notice of the latest result.
    static let mismatchDismissedKey = "integrity_mismatch_dismissed:"
    /// Strays trashed per run at most: a mismatch between listing and database must not empty a view.
    static let strayShortcutCap = 200

    let env: EngineEnvironment

    struct DoneJob: Sendable {
        var identity: JobIdentity
        var remoteId: String
        var uploadedHash: String?
        var expectedSize: Int64?
    }

    // MARK: Entry points

    /// One destination, or every available destination when `id` is nil. A destination that
    /// cannot be reached is skipped and named in the report: it never ends the check of the others.
    func run(_ id: DestinationID?) async throws -> IntegrityReport {
        var report = IntegrityReport()
        let records = try await env.store.read { db in try DestinationRepository.fetchAll(db) }
        for record in records where id == nil || record.id == id {
            guard !record.recoveryRequired, !Self.isLocationProblem(record.status),
                  let destination = await env.destinations.destination(for: record.id) else {
                report.skippedDestinations.append(record.id)
                continue
            }
            do {
                // A trashed or missing root (or a paused-for-folder destination) is a problem for
                // the owner to resolve: nothing under it can be judged, so nothing is marked missing.
                guard try await rootIsUsable(record, destination) else {
                    env.log.log(.notice, category: "integrity", "check skipped destination=\(record.id) root unavailable")
                    report.skippedDestinations.append(record.id)
                    continue
                }
                report.add(try await check(record, destination: destination))
            } catch let error as DestinationError where id == nil || Self.isUnreachable(error) {
                env.log.log(.notice, category: "integrity", "check skipped destination=\(record.id) error=\(error)")
                report.skippedDestinations.append(record.id)
            }
        }
        return report
    }

    private static func isLocationProblem(_ status: DestinationStatus) -> Bool {
        [.paused(.rootMissing), .paused(.rootTrashed), .paused(.folderTrashed)].contains(status)
    }

    private func rootIsUsable(_ record: DestinationRecord, _ destination: any Destination) async throws -> Bool {
        guard let managing = destination as? any RootManaging, let rootId = record.config.driveRootId, !rootId.isEmpty else { return true }
        if case .ok = try await managing.checkRoot(remoteId: rootId) { return true }
        return false
    }

    private static func isUnreachable(_ error: DestinationError) -> Bool {
        if case .destinationLevel = ErrorClassifier.classify(error) { return true }
        return false
    }

    func check(_ record: DestinationRecord, destination: any Destination) async throws -> IntegrityReport {
        var report = destination.capabilities.supportsAppProperties
            ? try await checkDrive(record, destination: destination)
            : try await checkLocal(record, destination: destination)
        let id = record.id
        let now = env.clock.now
        report.failedMoves = try await env.store.read { db in try MoveJobRepository.fetch(db, destinationId: id, state: .failed).count }
        report.missingByDestination[id] = report.missing
        if report.sizeMismatch + report.hashMismatch > 0 { report.mismatchByDestination[id] = report.sizeMismatch + report.hashMismatch }
        let summary = report
        try await env.store.write { db in
            try KeyValueRepository.set(db, Self.lastRunKey + id.rawValue, now)
            try KeyValueRepository.set(db, Self.resultMissingKey + id.rawValue, summary.missing)
            try KeyValueRepository.set(db, Self.resultMismatchKey + id.rawValue, summary.sizeMismatch + summary.hashMismatch)
            try KeyValueRepository.set(db, Self.resultAtKey + id.rawValue, now)
            try KeyValueRepository.set(db, Self.mismatchDismissedKey + id.rawValue, nil)
            if summary.totalProblems > 0 {
                try ActivityRepository.record(db, ActivityEvent(
                    at: now, kind: .missingFile, destinationId: id,
                    message: "Kiểm tra toàn vẹn: \(summary.totalProblems) file không còn nguyên vẹn ở đích; cần xác nhận trước khi upload lại"))
            }
        }
        env.log.log(.info, category: "integrity", "destination=\(id) checked=\(report.checked) problems=\(report.totalProblems)")
        return report
    }

    /// The owner confirmed: every `missingRemote` file of the destination is uploaded again (T20).
    @discardableResult
    func confirmReupload(_ id: DestinationID) async throws -> Int {
        let now = env.clock.now
        return try await env.store.write { db in
            var count = 0
            try KeyValueRepository.set(db, Self.resultMismatchKey + id.rawValue, nil)
            for job in try JobRepository.fetch(db, state: .missingRemote, destinationId: id) {
                _ = try JobRepository.apply(db, .reuploadConfirmed, to: job.identity, now: now)
                try DirtyQueue.mark(db, asset: job.assetKey)
                count += 1
            }
            return count
        }
    }

    /// The owner has seen the mismatch notice of the latest result.
    func dismissMismatch(_ id: DestinationID) async throws {
        try await env.store.write { db in try KeyValueRepository.set(db, Self.mismatchDismissedKey + id.rawValue, 1) }
    }

    // MARK: Shared

    func doneJobs(_ id: DestinationID) async throws -> [DoneJob] {
        try await env.store.read { db in
            try Row.fetchAll(db, sql: """
                SELECT j.asset_key, j.res_type, j.remote_id, j.uploaded_hash, r.size_bytes
                FROM upload_job j LEFT JOIN resource r ON r.asset_key = j.asset_key AND r.res_type = j.res_type
                WHERE j.destination_id = ? AND j.state = 'done' AND j.remote_id IS NOT NULL ORDER BY j.id
                """, arguments: [id.rawValue]).compactMap { row in
                guard let key = AssetKey(rawValue: row["asset_key"]) else { return nil }
                return DoneJob(
                    identity: JobIdentity(destinationId: id, assetKey: key, resType: ResourceType(rawValue: row["res_type"])),
                    remoteId: row["remote_id"], uploadedHash: row["uploaded_hash"], expectedSize: row["size_bytes"])
            }
        }
    }

    /// Marks jobs missing, but only those that are still exactly what the check looked at: a job
    /// that was refreshed or moved since the snapshot (other `remoteId` or hash) is not judged by
    /// an old picture. Returns the jobs that were marked.
    @discardableResult
    func markMissing(_ jobs: [DoneJob]) async throws -> Set<JobIdentity> {
        guard !jobs.isEmpty else { return [] }
        let now = env.clock.now
        return try await env.store.write { db in
            var marked = Set<JobIdentity>()
            for snapshot in jobs {
                guard let current = try JobRepository.fetch(db, identity: snapshot.identity), current.state == .done,
                      current.remoteId == snapshot.remoteId, current.uploadedHash == snapshot.uploadedHash else { continue }
                do {
                    _ = try JobRepository.apply(db, .missingAtDestination, to: snapshot.identity, now: now)
                    try DirtyQueue.mark(db, [.view], asset: snapshot.identity.assetKey)
                    marked.insert(snapshot.identity)
                } catch is JobTransitionError {
                    continue
                }
            }
            return marked
        }
    }
}

/// FR-47 every `integrityCheckIntervalDays` (7 by default); the owner can run it any time.
struct IntegrityStage: CycleStage {
    let env: EngineEnvironment
    var step: CycleStep { .cloudIds }

    func run(trigger: SyncTrigger) async throws -> Bool {
        let now = env.clock.now
        let days = await env.settingsSnapshot().settings.integrityCheckIntervalDays
        let interval = TimeInterval(max(1, days)) * 24 * 3600
        let due: [DestinationID] = try await env.store.write { db in
            var ids: [DestinationID] = []
            for record in try DestinationRepository.fetchAll(db) where record.acceptsUploads {
                guard let last = try KeyValueRepository.date(db, IntegrityChecker.lastRunKey + record.id.rawValue) else {
                    // First sight: the interval counts from now.
                    try KeyValueRepository.set(db, IntegrityChecker.lastRunKey + record.id.rawValue, now)
                    continue
                }
                if now.timeIntervalSince(last) >= interval { ids.append(record.id) }
            }
            return ids
        }
        var worked = false
        for id in due {
            do {
                _ = try await IntegrityChecker(env: env).run(id)
                worked = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                env.log.log(.notice, category: "integrity", "periodic check failed type=\(type(of: error))")
            }
        }
        return worked
    }
}
