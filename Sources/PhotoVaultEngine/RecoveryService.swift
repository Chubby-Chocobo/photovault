import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Recovery from a destination (FR-51, spec 8.15). It only runs when the scan is `complete` and
/// FR-53 has finished. While it runs, and until the owner settles a doubtful result, the
/// destination is `paused(recovering)` and receives nothing. What cannot be matched is logged and
/// never touched.
actor RecoveryService {
    static let decisionKey = "recovery_decision:"
    static let expectsKey = "recovery_expects:"
    static let enqueueKey = "recovery_enqueue:"
    private static let previousKey = "recovery_prev:"
    /// Share of the files found at the destination that must match before recovery goes on by itself.
    static let minimumMatchRatio = 0.5

    private let env: EngineEnvironment
    private let backfill: CloudIdBackfill
    private let finalize: FinalizePass
    private let eligibility: EligibilityService
    private let uploader: UploadRunner
    private let afterRecovery: @Sendable () async throws -> Void
    private var active = Set<DestinationID>()

    init(env: EngineEnvironment, backfill: CloudIdBackfill, finalize: FinalizePass, eligibility: EligibilityService,
         uploader: UploadRunner, afterRecovery: @escaping @Sendable () async throws -> Void) {
        self.env = env
        self.backfill = backfill
        self.finalize = finalize
        self.eligibility = eligibility
        self.uploader = uploader
        self.afterRecovery = afterRecovery
    }

    // MARK: Cycle entry

    /// Destinations that wait for recovery and for which the owner has not been asked.
    func hasWork() async -> Bool {
        let env = env
        return (try? await env.store.read { db in
            try DestinationRepository.fetchAll(db).contains { record in
                let decision = try KeyValueRepository.int(db, Self.decisionKey + record.id.rawValue) == 1
                let enqueue = try KeyValueRepository.int(db, Self.enqueueKey + record.id.rawValue) == 1
                return (record.recoveryRequired && !decision) || enqueue
            }
        }) ?? false
    }

    @discardableResult
    func runPending() async throws -> [DestinationID: RecoveryOutcome] {
        var outcomes: [DestinationID: RecoveryOutcome] = [:]
        let ids: [(DestinationID, Bool, Bool)] = try await env.store.read { db in
            try DestinationRepository.fetchAll(db).map { record in
                let decision = try KeyValueRepository.int(db, Self.decisionKey + record.id.rawValue) == 1
                let enqueue = try KeyValueRepository.int(db, Self.enqueueKey + record.id.rawValue) == 1
                return (record.id, record.recoveryRequired && !decision, enqueue)
            }
        }
        // Destinations with app properties first: their folders carry the logical paths, so a local
        // destination recovered after them is bound to the truth instead of guessing.
        var withProperties = Set<DestinationID>()
        for (id, _, _) in ids where await supportsAppProperties(id) { withProperties.insert(id) }
        let ordered = ids.filter { withProperties.contains($0.0) } + ids.filter { !withProperties.contains($0.0) }
        for (id, needsRecovery, needsEnqueue) in ordered {
            try Task.checkCancellation()
            do {
                if needsRecovery {
                    outcomes[id] = try await recover(id)
                } else if needsEnqueue {
                    try await enqueueRest(id)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One destination's trouble must not stop the cycle for the others; it is retried next cycle.
                env.log.log(.notice, category: "recovery", "destination=\(id) not recovered type=\(type(of: error))")
                outcomes[id] = .notReady(.destinationUnavailable)
            }
        }
        return outcomes
    }

    // MARK: Order

    private func supportsAppProperties(_ id: DestinationID) async -> Bool {
        await env.destinations.destination(for: id)?.capabilities.supportsAppProperties == true
    }

    /// A registered destination with app properties (Drive) that is still waiting for its recovery.
    private func driveNeedsRecovery() async throws -> Bool {
        let waiting = try await env.store.read { db in try DestinationRepository.fetchAll(db).filter(\.recoveryRequired).map(\.id) }
        for id in waiting where await supportsAppProperties(id) { return true }
        return false
    }

    // MARK: Recovery

    func recover(_ id: DestinationID) async throws -> RecoveryOutcome {
        guard !active.contains(id) else { return .notReady(.alreadyRunning) }
        if !(await supportsAppProperties(id)), try await driveNeedsRecovery() { return .notReady(.waitingForDrive) }
        active.insert(id)
        defer { active.remove(id) }
        guard let record = try await env.store.read({ db in try DestinationRepository.fetch(db, id: id) }),
              let destination = await env.destinations.destination(for: id) else { return .notReady(.unknownDestination) }
        guard try await env.store.read({ db in try KeyValueRepository.scanState(db) }) == .complete else { return .notReady(.scanIncomplete) }
        do {
            try await backfill.runAll(force: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            env.log.log(.notice, category: "recovery", "cloud id backfill failed type=\(type(of: error))")
            return .notReady(.cloudIdsPending)
        }
        guard await destination.checkAvailability() == .active else { return .notReady(.destinationUnavailable) }
        try await enter(record)
        do {
            return try await run(record: record, destination: destination)
        } catch let error as DestinationError {
            env.log.log(.notice, category: "recovery", "destination error during recovery error=\(error)")
            return .notReady(.destinationUnavailable)
        }
    }

    /// `paused(recovering)`; the status the owner had chosen is remembered.
    private func enter(_ record: DestinationRecord) async throws {
        let id = record.id
        let now = env.clock.now
        let owner = record.status == .paused(.userPaused)
        try await env.store.write { db in
            if owner { try KeyValueRepository.set(db, Self.previousKey + id.rawValue, 1) }
            try DestinationRepository.setRecoveryRequired(db, id: id, true)
            try DestinationRepository.setStatus(db, id: id, status: .paused(.recovering), now: now)
            try KeyValueRepository.set(db, Self.decisionKey + id.rawValue, nil)
        }
    }

    private func run(record: DestinationRecord, destination: any Destination) async throws -> RecoveryOutcome {
        var inventory = try await RemoteInventoryLoader(env: env, record: record, destination: destination).load()
        if inventory.legacyFolders > 0 {
            env.log.log(.notice, category: "recovery", "root holds the old folder layout; recovery refused")
            return .notReady(.legacyLayout)
        }
        let zone = try await restoreTimezone(inventory.archiveTimezone)
        let (known, rows) = try await knownSlots(for: inventory, destinationId: record.id)
        let isDrive = destination.capabilities.supportsAppProperties
        let provisional = try await env.store.read { db in try ProvisionalSlots.days(db) }
        let bound = DaySlotBinding.bind(inventory, known: known, rows: rows, isDrive: isDrive, provisionalDays: provisional)
        inventory = bound.inventory
        if isDrive, !provisional.isEmpty {
            // Drive's slots are the truth: what a local recovery guessed is rebound to them, and nothing moves at Drive.
            let truth = inventory.folders
            try await env.store.write { db in try ProvisionalSlots.resolve(db, truth: truth, days: provisional) }
        }
        var stats = RecoveryStats()
        stats.found = try await walkedFileCount(record: record, destination: destination)
        let matches = try await RecoveryMatcher(env: env, record: record, timeZone: zone).match(inventory)
        stats.matched = matches.files.count
        stats.unmatched = matches.unmatched.count
        let total = max(stats.found, inventory.files.count)
        let expects = try await expectsContent(record.id)
        if (total > 0 && Double(stats.matched) / Double(total) < Self.minimumMatchRatio) || (total == 0 && expects) {
            try await askOwner(record.id, stats: stats)
            return .needsOwnerDecision(stats)
        }
        let writer = RecoveryWriter(env: env, record: record, timeZone: zone)
        try await writer.releaseUnconfirmedPlacements()
        let daysWithRows = try await env.store.read { db in try DayPlaceRepository.days(db) }
        let folders = try await writer.writeFolders(inventory.folders, listedIds: Set(inventory.folders.map(\.remoteId)))
        stats.folders = folders.written
        stats.folderConflicts = bound.conflicts + folders.conflicts
        if stats.folderConflicts > 0 { try await reportFolderConflicts(record.id, count: stats.folderConflicts) }
        if !bound.guessed.isEmpty {
            let guessed = bound.guessed
            try await env.store.write { db in try ProvisionalSlots.mark(db, guessed) }
        }
        let written = try await writer.writeFiles(matches.files, daysWithRows: daysWithRows)
        stats.suspect = written.suspect
        stats.shortcuts = try await writer.writeShortcuts(matches.shortcuts)
        env.log.log(.info, category: "recovery", "destination=\(record.id) matched=\(stats.matched) unmatched=\(stats.unmatched) folders=\(stats.folders)")
        try await finish(record, stats: stats, verifyLocal: !destination.capabilities.supportsAppProperties)
        return .recovered(stats)
    }

    // MARK: Pieces

    /// Day state tied to the old archive timezone is worthless in the restored one.
    static func clearDayState(env: EngineEnvironment) async throws {
        try await env.store.write { db in
            try db.execute(sql: "DELETE FROM day_stat")
            try DayPlaceRepository.deleteAll(db)
            try AssetPlacementRepository.clearPlaceSlots(db)
        }
    }

    /// What the database knows about the camera days listed at a destination, for `DaySlotBinding`.
    private func knownSlots(for inventory: RemoteInventory, destinationId id: DestinationID) async throws -> (known: [ArchiveDay: [DaySlot]], rows: [RemoteFolder]) {
        let days = Set(inventory.folders.compactMap(\.day))
        return try await env.store.read { db in
            var known: [ArchiveDay: [DaySlot]] = [:]
            for day in days {
                var slots: [DaySlot] = []
                if let stat = try DayStatRepository.fetch(db, day: day) {
                    slots.append(DaySlot(slot: nil, key: stat.placeKey, name: stat.placeName, reservedNames: try DaySplitWriter.reserved(db, day: day, slot: nil)))
                }
                for row in try DayPlaceRepository.fetchAll(db, day: day) {
                    slots.append(DaySlot(slot: row.slot, key: row.placeKey, name: row.placeName, reservedNames: try DaySplitWriter.reserved(db, day: day, slot: row.slot)))
                }
                known[day] = slots
            }
            return (known, try RemoteFolderRepository.fetchAll(db, destinationId: id))
        }
    }


    /// The archive timezone the destination remembers wins while nothing of the database is
    /// confirmed by a file: names are fingerprinted in that zone (8.15 step 4.3).
    private func restoreTimezone(_ identifier: String?) async throws -> TimeZone {
        let current = await env.settings.snapshot().timeZone
        guard let identifier, let zone = TimeZone(identifier: identifier), zone.identifier != current.identifier else { return current }
        let history = try await env.store.read { db in
            try Int.fetchOne(db, sql: """
                SELECT 1 FROM upload_job WHERE state IN ('done', 'uploading', 'missingRemote') OR remote_id IS NOT NULL LIMIT 1
                """) != nil
        }
        guard !history else { return current }
        try await env.settings.setArchiveTimeZone(zone)
        // Day counts made with the other zone are worthless; they are recounted as assets are placed.
        try await Self.clearDayState(env: env)
        return zone
    }

    /// An independent walk of the root, folder by folder, as a person browsing the tree would see
    /// it: the guard compares it with what matched. Drive lists the children of one folder at a
    /// time; a local walk already covers the whole tree.
    private func walkedFileCount(record: DestinationRecord, destination: any Destination) async throws -> Int {
        let isDrive = destination.capabilities.supportsAppProperties
        var files = Set<String>()
        var visited = Set<String>()
        var queue = [RemoteFolderRef.root(remoteId: record.config.driveRootId ?? "")]
        while let folder = queue.popLast() {
            guard visited.insert(folder.remoteId).inserted else { continue }
            for try await item in destination.list(under: folder) {
                try Task.checkCancellation()
                guard !item.trashed else { continue }
                if item.kind == .file, isDrive || NameFingerprint.parse(item.name) != nil {
                    files.insert(item.remoteId)
                } else if item.kind == .folder, isDrive {
                    queue.append(RemoteFolderRef(logicalPath: "", remoteId: item.remoteId, displayPath: ""))
                }
            }
        }
        return files.count
    }

    private func expectsContent(_ id: DestinationID) async throws -> Bool {
        try await env.store.read { db in
            if try KeyValueRepository.int(db, Self.expectsKey + id.rawValue) == 1 { return true }
            return try JobRepository.count(db, destinationId: id, state: .done) > 0
        }
    }

    /// Two folders claimed one logical path, or a write would have made two paths share a folder:
    /// the extra folders are left out of the database and their files are not adopted.
    private func reportFolderConflicts(_ id: DestinationID, count: Int) async throws {
        let now = env.clock.now
        env.log.log(.notice, category: "recovery", "destination=\(id) folder conflicts=\(count)")
        try await env.store.write { db in
            try ActivityRepository.record(db, ActivityEvent(
                at: now, kind: .notice, destinationId: id,
                message: tr(
                    vi: "Khôi phục: \(count) thư mục trùng đường dẫn nên không được ghép; các file trong đó không bị đụng tới",
                    en: "Recovery: \(count) \(L10n.plural(count, one: "folder", other: "folders")) claimed a path already in use and was left out; its files are untouched")))
        }
    }

    private func askOwner(_ id: DestinationID, stats: RecoveryStats) async throws {
        let now = env.clock.now
        try await env.store.write { db in
            try KeyValueRepository.set(db, Self.decisionKey + id.rawValue, 1)
            try ActivityRepository.record(db, ActivityEvent(
                at: now, kind: .notice, destinationId: id,
                message: tr(
                    vi: "Khôi phục từ đích: tìm thấy \(stats.found) file nhưng chỉ ghép được \(stats.matched); cần owner quyết định trước khi upload",
                    en: L10n.plural(
                        stats.found,
                        one: "Recovery from the destination: found \(stats.found) file but matched only \(stats.matched); the owner must decide before uploading",
                        other: "Recovery from the destination: found \(stats.found) files but matched only \(stats.matched); the owner must decide before uploading"))))
        }
        env.log.log(.notice, category: "recovery", "destination=\(id) needs owner decision found=\(stats.found) matched=\(stats.matched)")
    }

    private func finish(_ record: DestinationRecord, stats: RecoveryStats, verifyLocal: Bool) async throws {
        let id = record.id
        let now = env.clock.now
        let verify = verifyLocal && env.localContent != nil
        try await env.store.write { db in
            let owner = try KeyValueRepository.int(db, Self.previousKey + id.rawValue) == 1
            try DestinationRepository.setStatus(db, id: id, status: owner ? .paused(.userPaused) : .active, now: now)
            try DestinationRepository.setRecoveryRequired(db, id: id, false)
            for prefix in [Self.previousKey, Self.decisionKey, Self.expectsKey] { try KeyValueRepository.set(db, prefix + id.rawValue, nil) }
            try KeyValueRepository.set(db, Self.enqueueKey + id.rawValue, 1)
            try KeyValueRepository.set(db, RecoveryTriggers.probeKey + id.rawValue, 1)
            if verify { try RecoveryVerifier.schedule(db, destinationId: id) }
            try ActivityRepository.record(db, ActivityEvent(
                at: now, kind: .recovered, destinationId: id,
                message: tr(
                    vi: "Đã khôi phục \(stats.matched) file từ đích, \(stats.unmatched) file không ghép được (không bị đụng tới)",
                    en: "Recovered \(stats.matched) \(L10n.plural(stats.matched, one: "file", other: "files")) from the destination, \(stats.unmatched) \(L10n.plural(stats.unmatched, one: "file", other: "files")) could not be matched (left untouched)")))
        }
        try await enqueueRest(id)
    }

    /// Step 8: place what is still unplaced and queue the rest per scope.
    func enqueueRest(_ id: DestinationID) async throws {
        await uploader.forget(id)
        try await finalize.placeLeftovers()
        try await eligibility.recomputeAll(destination: id, backfillOrigin: .destinationBackfill)
        try await afterRecovery()
        try await env.store.write { db in try KeyValueRepository.set(db, Self.enqueueKey + id.rawValue, nil) }
    }

    // MARK: Owner decision

    /// The owner accepts that nothing at the destination is used: it goes active and everything is queued.
    func proceedWithoutRecovery(_ id: DestinationID) async throws {
        guard let record = try await env.store.read({ db in try DestinationRepository.fetch(db, id: id) }) else { return }
        try await finish(record, stats: RecoveryStats(), verifyLocal: false)
    }

    func needsDecision(_ id: DestinationID) async -> Bool {
        let env = env
        return ((try? await env.store.read { db in try KeyValueRepository.int(db, Self.decisionKey + id.rawValue) == 1 }) ?? false)
    }
}
