import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// The engine's single entry point: runs the spec 8.4 cycle.
///
/// 1 checks · 2 scan / change tracking · 3 classify · 4 export · 5 [stage] · 6 fan-out ·
/// 7–9 [stages] · 10 [stage] · 11 publish. Steps 3–9 repeat while they make progress, so a large
/// backlog drains within one cycle (staging is released by uploads, which lets more exports in).
/// Single-flight: a trigger that arrives while a cycle runs schedules exactly one follow-up.
public actor SyncCoordinator {
    private let env: EngineEnvironment
    private let stages: [any CycleStage]
    let organization: OrganizationServices
    private let reconciler: (any ReconciliationRunning)?
    let staging: StagingManager
    let resourceGuard: ResourceGuard
    let baseline: Baseline
    let scanner: Scanner
    let tracker: ChangeTracker
    let finalize: FinalizePass
    let eligibility: EligibilityService
    let classifier: ClassifyWorker
    let exporter: ExportWorker
    let uploader: UploadRunner
    let recovery: StartupRecovery

    private var running = false
    private var followUp = false
    private var followUpTrigger: SyncTrigger = .manual
    private var globallyPaused = false
    private var needsReconciliation: ReconciliationReason?
    private var lastCheckBlock: CycleBlock?
    private var lastNetworkOK = true
    private var lastPublished: EngineSnapshot?
    private var subscribers: [UUID: AsyncStream<EngineSnapshot>.Continuation] = [:]
    private var backfillObservation: (at: Date, done: Int)?

    public init(
        env: EngineEnvironment, stages: [any CycleStage] = [], reconciler: (any ReconciliationRunning)? = nil,
        recoveryParticipants: [any RecoveryParticipant] = []
    ) {
        self.init(env: env, stages: stages, reconciler: reconciler, recoveryParticipants: recoveryParticipants, planningExtensions: [])
    }

    /// Module-internal initializer for later phases: `planningExtensions` create the job kinds the
    /// eligibility pass leaves alone (sidecars), inside the same transactions.
    init(
        env: EngineEnvironment, stages: [any CycleStage], reconciler: (any ReconciliationRunning)?,
        recoveryParticipants: [any RecoveryParticipant], planningExtensions: [any JobPlanningExtension]
    ) {
        self.env = env
        self.reconciler = reconciler
        let extensions = planningExtensions + [SidecarPlanner()]
        let staging = StagingManager(env: env)
        let guardActor = ResourceGuard(env: env, staging: staging)
        let uploadRunner = UploadRunner(env: env, staging: staging)
        let services = OrganizationServices(env: env, uploader: uploadRunner, resourceGuard: guardActor)
        organization = services
        self.stages = stages + services.stages
        self.staging = staging
        resourceGuard = guardActor
        baseline = Baseline(env: env)
        scanner = Scanner(env: env)
        tracker = ChangeTracker(env: env, extensions: extensions)
        finalize = FinalizePass(env: env, extensions: extensions)
        eligibility = EligibilityService(env: env, extensions: extensions)
        classifier = ClassifyWorker(env: env, resourceGuard: guardActor, staging: staging, extensions: extensions)
        exporter = ExportWorker(env: env, resourceGuard: guardActor, staging: staging)
        uploader = uploadRunner
        recovery = StartupRecovery(env: env, staging: staging, participants: recoveryParticipants + [MoveRecovery(env: env)])
    }

    // MARK: Lifecycle

    /// Startup recovery (spec 8.3); call once before the first cycle.
    @discardableResult
    public func start() async throws -> RecoverySummary { try await recovery.run() }

    /// FR-15: takes the baseline for the given destinations (once). The next cycle scans.
    public func beginBaseline(destinations: [DestinationID]) async throws {
        try await baseline.take(destinations: destinations)
    }

    // MARK: Pause

    public func pauseAll() async {
        globallyPaused = true
        await publish()
    }

    public func resumeAll() async {
        globallyPaused = false
        await publish()
    }

    public func pause(destination id: DestinationID) async throws {
        let now = env.clock.now
        try await env.store.write { db in try DestinationRepository.setStatus(db, id: id, status: .paused(.userPaused), now: now) }
        await publish()
    }

    public func resume(destination id: DestinationID) async throws {
        let now = env.clock.now
        try await env.store.write { db in
            if try DestinationRepository.fetch(db, id: id)?.status == .paused(.userPaused) {
                try DestinationRepository.setStatus(db, id: id, status: .active, now: now)
            }
        }
        await publish()
    }

    // MARK: Configuration changes

    /// Call after global settings changed: recomputes the destination set for every asset (FR-19).
    public func settingsChanged() async throws {
        try await eligibility.recomputeAll()
        try await organization.settingsChanged()
        await publish()
    }

    /// Call after a destination was added to the store and the registry: enqueues from the
    /// database, never by rescanning (FR-71).
    public func destinationAdded(_ id: DestinationID) async throws {
        try await eligibility.recomputeAll(destination: id, backfillOrigin: .destinationBackfill)
        try await organization.settingsChanged()
        await publish()
    }

    /// Call after a destination's scope or rules changed.
    public func destinationRulesChanged(_ id: DestinationID) async throws {
        try await eligibility.recomputeAll(destination: id, backfillOrigin: .backfill)
        await publish()
    }

    public func destinationRemoved(_ id: DestinationID) async {
        await env.destinations.remove(id)
        await uploader.forget(id)
        await publish()
    }

    // MARK: Cycle

    public func run(trigger: SyncTrigger) async -> CycleOutcome {
        if running {
            followUp = true
            followUpTrigger = trigger
            return .queued
        }
        running = true
        var outcome = await runGuarded(trigger)
        while followUp {
            followUp = false
            outcome = await runGuarded(followUpTrigger)
        }
        running = false
        await publish()
        return outcome
    }

    private func runGuarded(_ trigger: SyncTrigger) async -> CycleOutcome {
        if globallyPaused { return .paused }
        await publish()
        do {
            return try await cycle(trigger)
        } catch is CancellationError {
            return .completed(CycleReport())
        } catch {
            env.log.log(.error, category: "cycle", "cycle ended with error: \(type(of: error))")
            return .completed(CycleReport())
        }
    }

    private func cycle(_ trigger: SyncTrigger) async throws -> CycleOutcome {
        var report = CycleReport()
        // 1. checks
        guard env.photos.authorizationStatus().allowsReading else {
            lastCheckBlock = .photosUnauthorized
            return .blocked(.photosUnauthorized)
        }
        guard baseline.isTaken else {
            lastCheckBlock = .notBaselined
            return .blocked(.notBaselined)
        }
        lastCheckBlock = nil
        let settings = await env.settingsSnapshot().settings
        let system = await env.system.snapshot()
        lastNetworkOK = system.networkAvailable
        let uploadsAllowed = system.networkAvailable
            && !(settings.pauseOnExpensiveNetwork && (system.networkExpensive || system.networkConstrained))
            && !(settings.allUploadsOnlyOnACPower && !system.onACPower)
        report.uploadsHeld = !uploadsAllowed
        try await DestinationHealth(env: env).refresh()
        _ = try await recovery.resolveInterrupted()
        try await DeferredJobSweeper(env: env).sweep()
        try await runStages(.checks, trigger, &report)

        // 2. scan, change tracking
        let scan = try await scanner.run()
        report.scanned = scan.scanned
        if scan.state == .complete {
            switch try await tracker.process() {
            case .upToDate(let processed):
                report.changesProcessed = processed
                needsReconciliation = nil
            case .needsReconciliation(let reason):
                if let reconciler {
                    try await reconciler.reconcile(reason: reason)
                    needsReconciliation = nil
                } else {
                    needsReconciliation = reason
                    report.needsReconciliation = reason
                }
            case .scanIncomplete: break
            }
            try await finalize.runAfterScan()
        }
        try await runStages(.changes, trigger, &report)

        // 3–9. repeat while there is progress
        while report.rounds < env.tuning.maxCycleIterations {
            try Task.checkCancellation()
            report.rounds += 1
            await resourceGuard.enforce()
            var progress = 0
            let classified = try await classifier.runPass()
            report.classified += classified.classified
            progress += classified.classified
            try await runStages(.classify, trigger, &report, progress: &progress)
            let exported = try await exporter.runPass()
            report.exported += exported.exported
            progress += exported.exported + exported.skippedByRule
            try await runStages(.export, trigger, &report, progress: &progress)
            try await runStages(.editGate, trigger, &report, progress: &progress)
            if uploadsAllowed {
                let uploaded = try await uploader.runPass()
                report.uploaded += uploaded.uploaded
                progress += uploaded.uploaded
            }
            for step in [CycleStep.fanOut, .sidecarsAndViews, .moves, .placeNamer] {
                try await runStages(step, trigger, &report, progress: &progress)
            }
            try await staging.releaseUnneeded()
            try await staging.expireIdle()
            if progress == 0 { break }
        }

        // 10–11
        try await runStages(.cloudIds, trigger, &report)
        try await recordSuccess()
        await publish()
        return .completed(report)
    }

    private func runStages(_ step: CycleStep, _ trigger: SyncTrigger, _ report: inout CycleReport) async throws {
        var ignored = 0
        try await runStages(step, trigger, &report, progress: &ignored)
    }

    private func runStages(_ step: CycleStep, _ trigger: SyncTrigger, _ report: inout CycleReport, progress: inout Int) async throws {
        for stage in stages where stage.step == step {
            if try await stage.run(trigger: trigger) {
                report.stageWork += 1
                progress += 1
            }
        }
    }

    private func recordSuccess() async throws {
        let now = env.clock.now
        try await env.store.write { db in try KeyValueRepository.set(db, KeyValueRepository.Key.lastSuccessfulSyncAt, now) }
    }

    // MARK: Observation

    /// Stream of snapshots; the latest one is replayed to a new subscriber.
    public func snapshots() -> AsyncStream<EngineSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: EngineSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = continuation
        if let lastPublished { continuation.yield(lastPublished) }
        continuation.onTermination = { _ in Task { await self.removeSubscriber(id) } }
        return stream
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    public func currentSnapshot() async -> EngineSnapshot {
        (try? await buildSnapshot()) ?? lastPublished ?? EngineSnapshot.empty(at: env.clock.now)
    }

    private func publish() async {
        guard let snapshot = try? await buildSnapshot() else { return }
        lastPublished = snapshot
        for continuation in subscribers.values { continuation.yield(snapshot) }
    }

    private func buildSnapshot() async throws -> EngineSnapshot {
        let raw = try await SnapshotBuilder(env: env).read()
        let now = env.clock.now
        var eta: TimeInterval?
        if raw.backfill.total > 0 {
            if backfillObservation == nil { backfillObservation = (now, raw.backfill.done) }
            if let observed = backfillObservation {
                let elapsed = now.timeIntervalSince(observed.at)
                let finished = raw.backfill.done - observed.done
                if elapsed > 0, finished > 0 {
                    eta = Double(raw.backfill.total - raw.backfill.done) / (Double(finished) / elapsed)
                }
            }
        }
        let overall: EngineSnapshot.Overall
        if globallyPaused {
            overall = .paused
        } else if lastCheckBlock == .photosUnauthorized {
            overall = .photosUnauthorized
        } else if lastCheckBlock == .notBaselined {
            overall = .notBaselined
        } else if running {
            overall = .syncing
        } else if needsReconciliation != nil {
            overall = .needsReconciliation
        } else if !lastNetworkOK {
            overall = .offline
        } else {
            overall = .idle
        }
        return EngineSnapshot(
            overall: overall, scanState: raw.scan, destinations: raw.destinations, backfillDoneAssets: raw.backfill.done,
            backfillTotalAssets: raw.backfill.total, bytesUploaded: raw.bytes, etaSeconds: eta,
            pending: raw.totals.pending + raw.totals.uploading, deferred: raw.totals.deferred, skipped: raw.totals.skipped,
            missingRemote: raw.totals.missingRemote, updatedAt: now)
    }
}

extension EngineSnapshot {
    static func empty(at date: Date) -> EngineSnapshot {
        EngineSnapshot(
            overall: .idle, scanState: .notStarted, destinations: [], backfillDoneAssets: 0, backfillTotalAssets: 0,
            bytesUploaded: 0, etaSeconds: nil, pending: 0, deferred: 0, skipped: 0, missingRemote: 0, updatedAt: date)
    }
}
