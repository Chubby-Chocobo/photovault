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

    /// One destination, or every available destination when `id` is nil.
    func run(_ id: DestinationID?) async throws -> IntegrityReport {
        var report = IntegrityReport()
        let records = try await env.store.read { db in try DestinationRepository.fetchAll(db) }
        for record in records where id == nil || record.id == id {
            guard !record.recoveryRequired, let destination = await env.destinations.destination(for: record.id) else { continue }
            do {
                report.add(try await check(record, destination: destination))
            } catch let error as DestinationError where id == nil {
                env.log.log(.notice, category: "integrity", "check skipped destination=\(record.id) error=\(error)")
            }
        }
        return report
    }

    func check(_ record: DestinationRecord, destination: any Destination) async throws -> IntegrityReport {
        var report = destination.capabilities.supportsAppProperties
            ? try await checkDrive(record, destination: destination)
            : try await checkLocal(record, destination: destination)
        let id = record.id
        let now = env.clock.now
        report.failedMoves = try await env.store.read { db in try MoveJobRepository.fetch(db, destinationId: id, state: .failed).count }
        report.missingByDestination[id] = report.missing + report.sizeMismatch + report.hashMismatch
        let summary = report
        try await env.store.write { db in
            try KeyValueRepository.set(db, Self.lastRunKey + id.rawValue, now)
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
            for job in try JobRepository.fetch(db, state: .missingRemote, destinationId: id) {
                _ = try JobRepository.apply(db, .reuploadConfirmed, to: job.identity, now: now)
                try DirtyQueue.mark(db, asset: job.assetKey)
                count += 1
            }
            return count
        }
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

    // MARK: Drive

    private func checkDrive(_ record: DestinationRecord, destination: any Destination) async throws -> IntegrityReport {
        var report = IntegrityReport()
        // The database is read first, then the destination is listed: a file that finished after
        // the snapshot is not part of the check, and one that is in the snapshot but not in the
        // listing is asked for by id before it counts as missing.
        let id = record.id
        let jobs = try await doneJobs(id)
        let knownShortcuts = try await liveShortcuts(id)
        var items: [String: RemoteItem] = [:]
        for try await item in destination.list(under: nil) {
            try Task.checkCancellation()
            items[item.remoteId] = item
        }
        func isGone(_ id: String) -> Bool {
            var current = items[id]
            var hops = 0
            while let item = current, hops < 64 {
                if item.trashed { return true }
                current = item.parentIds.first.flatMap { items[$0] }
                hops += 1
            }
            return items[id] == nil
        }
        report.checked = jobs.count
        var gone: [DoneJob] = []
        for job in jobs where isGone(job.remoteId) {
            if items[job.remoteId] == nil, try await stillThere(job.remoteId, destination) { continue }
            gone.append(job)
        }
        report.missing = try await markMissing(gone).count
        try await healReturned(id, isGone: isGone)
        try await reconcileShortcuts(
            record, destination: destination, known: knownShortcuts, items: items, isGone: isGone, report: &report)
        return report
    }

    /// The listing did not show the item: ask for it by id. Errors other than "not found" end the check.
    private func stillThere(_ remoteId: String, _ destination: any Destination) async throws -> Bool {
        do {
            return try await destination.probe(remoteId: remoteId).map { !$0.trashed } ?? false
        } catch DestinationError.notFound {
            return false
        }
    }

    private func liveShortcuts(_ id: DestinationID) async throws -> [ShortcutRecord] {
        try await env.store.read { db in
            try [ShortcutState.done, .movePending].flatMap { try ShortcutRepository.fetch(db, destinationId: id, state: $0) }
        }
    }

    /// A file that was missing and is back (the owner restored it) is done again.
    private func healReturned(_ id: DestinationID, isGone: (String) -> Bool) async throws {
        let missing = try await env.store.read { db in try JobRepository.fetch(db, state: .missingRemote, destinationId: id) }
        let back = missing.filter { job in job.remoteId.map { !isGone($0) } ?? false }
        guard !back.isEmpty else { return }
        try await env.store.write { db in
            for job in back {
                try db.execute(sql: "UPDATE upload_job SET state = 'done' WHERE id = ? AND state = 'missingRemote'", arguments: [job.id])
            }
        }
    }

    /// Shortcuts the owner deleted stay deleted (`userRemoved`); app-made shortcuts the database
    /// does not know are trashed. Only shortcuts, never files or folders.
    private func reconcileShortcuts(
        _ record: DestinationRecord, destination: any Destination, known: [ShortcutRecord], items: [String: RemoteItem],
        isGone: (String) -> Bool, report: inout IntegrityReport
    ) async throws {
        let id = record.id
        var ownerRemoved: [ShortcutRecord] = []
        for shortcut in known {
            guard let shortcutId = shortcut.shortcutId, isGone(shortcutId) else { continue }
            if items[shortcutId] == nil, try await stillThere(shortcutId, destination) { continue }
            ownerRemoved.append(shortcut)
        }
        let removed = ownerRemoved
        if !removed.isEmpty {
            report.shortcutsRemoved = try await env.store.write { db in
                var changed = 0
                for var shortcut in removed {
                    // Only a shortcut that is still the one that was checked.
                    guard let current = try ShortcutRepository.fetch(db, destinationId: id, view: shortcut.view, assetKey: shortcut.assetKey),
                          current.shortcutId == shortcut.shortcutId, [.done, .movePending].contains(current.state) else { continue }
                    shortcut.state = .userRemoved
                    try ShortcutRepository.save(db, shortcut)
                    changed += 1
                }
                return changed
            }
        }
        guard let viewing = destination as? any ViewDestination else { return }
        let knownIds: Set<String> = try await env.store.read { db in
            Set(try String.fetchAll(db, sql: "SELECT shortcut_id FROM shortcut WHERE destination_id = ? AND shortcut_id IS NOT NULL", arguments: [id.rawValue]))
        }
        let strays = items.values.filter {
            $0.kind == .shortcut && !$0.trashed && $0.appProperties[AppPropertyKey.view] != nil && !knownIds.contains($0.remoteId)
        }.sorted { $0.remoteId < $1.remoteId }.prefix(Self.strayShortcutCap)
        for stray in strays {
            do {
                try await viewing.trashShortcut(remoteId: stray.remoteId)
                report.shortcutsTrashed += 1
            } catch DestinationError.notFound {
                continue
            }
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
