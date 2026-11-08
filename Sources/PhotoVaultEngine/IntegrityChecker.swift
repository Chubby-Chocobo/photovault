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

    func markMissing(_ identities: [JobIdentity]) async throws {
        guard !identities.isEmpty else { return }
        let now = env.clock.now
        try await env.store.write { db in
            for identity in identities {
                do {
                    _ = try JobRepository.apply(db, .missingAtDestination, to: identity, now: now)
                    try DirtyQueue.mark(db, [.view], asset: identity.assetKey)
                } catch is JobTransitionError {
                    continue
                }
            }
        }
    }

    // MARK: Drive

    private func checkDrive(_ record: DestinationRecord, destination: any Destination) async throws -> IntegrityReport {
        var report = IntegrityReport()
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
        let id = record.id
        let jobs = try await doneJobs(id)
        report.checked = jobs.count
        let gone = jobs.filter { isGone($0.remoteId) }
        report.missing = gone.count
        try await markMissing(gone.map(\.identity))
        try await healReturned(id, isGone: isGone)
        try await reconcileShortcuts(record, destination: destination, items: items, isGone: isGone, report: &report)
        return report
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
        _ record: DestinationRecord, destination: any Destination, items: [String: RemoteItem], isGone: (String) -> Bool,
        report: inout IntegrityReport
    ) async throws {
        let id = record.id
        let known: [ShortcutRecord] = try await env.store.read { db in
            try [ShortcutState.done, .movePending].flatMap { try ShortcutRepository.fetch(db, destinationId: id, state: $0) }
        }
        let ownerRemoved = known.filter { $0.shortcutId.map(isGone) ?? false }
        if !ownerRemoved.isEmpty {
            report.shortcutsRemoved = ownerRemoved.count
            try await env.store.write { db in
                for var shortcut in ownerRemoved {
                    shortcut.state = .userRemoved
                    try ShortcutRepository.save(db, shortcut)
                }
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

/// FR-47 every 7 days; the owner can run it any time.
struct IntegrityStage: CycleStage {
    let env: EngineEnvironment
    var step: CycleStep { .cloudIds }

    func run(trigger: SyncTrigger) async throws -> Bool {
        let now = env.clock.now
        let interval = env.tuning.integrityInterval
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
