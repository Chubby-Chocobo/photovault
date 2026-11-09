import Foundation
import PhotoVaultCore
import PhotoVaultStore
import GRDB

/// The spec 8.4 cycle and the lane it shares with owner commands.
///
/// A cycle can last for hours. Every pass boundary therefore (1) lets waiting owner commands run,
/// (2) re-reads pause, network, power and destination status, and (3) picks up Photos changes that
/// arrived meanwhile. The upload loop asks again before each job (`UploadGate`).
extension SyncCoordinator {
    // MARK: Lane

    /// Runs an owner command alone: it waits for the current cycle's next pass boundary and the
    /// cycle resumes after it. A command must not call `run` itself (call it after the command).
    @discardableResult
    func exclusive<T>(_ body: () async throws -> T) async rethrows -> T {
        await lane.beginCommand()
        let result: T
        do {
            result = try await body()
        } catch {
            await lane.endCommand()
            throw error
        }
        await lane.endCommand()
        return result
    }

    // MARK: Entry

    public func run(trigger: SyncTrigger) async -> CycleOutcome {
        if running {
            followUp = true
            followUpTrigger = trigger
            if trigger == .photosChanged { changesPending = true }
            return .queued
        }
        running = true
        await lane.beginCycle()
        var outcome = await runGuarded(trigger)
        while followUp {
            followUp = false
            outcome = await runGuarded(followUpTrigger)
        }
        // `running` is cleared before the lane is released: a trigger in between starts a cycle
        // that waits for the lane instead of being dropped.
        running = false
        await lane.endCycle()
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
            let failure = CycleFailure(error)
            env.log.log(.error, category: "cycle", "cycle ended with error: \(failure.errorType)")
            return .failed(failure)
        }
    }

    // MARK: Conditions

    /// Network, expensive / constrained network and AC power, read now.
    func uploadsAllowedNow() async -> Bool {
        let settings = await env.settingsSnapshot().settings
        let system = await env.system.snapshot()
        lastNetworkOK = system.networkAvailable
        return system.networkAvailable
            && !(settings.pauseOnExpensiveNetwork && (system.networkExpensive || system.networkConstrained))
            && !(settings.allUploadsOnlyOnACPower && !system.onACPower)
    }

    /// Asked before every upload job: nothing starts while paused, offline, off power (when the
    /// owner asked for it), while an owner command waits or while new Photos changes wait to be
    /// picked up (new photos go first).
    private func mayStartUpload() async -> Bool {
        guard !globallyPaused, !changesPending else { return false }
        if await lane.hasWaitingCommands {
            // The backlog was not finished: one more run after the command, not the next timer.
            followUp = true
            return false
        }
        return await uploadsAllowedNow()
    }

    // MARK: Cycle

    private func cycle(_ trigger: SyncTrigger) async throws -> CycleOutcome {
        var report = CycleReport()
        // 0. An old-layout database stays untouched: no export, upload, move, sidecar or view.
        guard try await !isLegacyLayoutBlocked() else {
            lastCheckBlock = .legacyLayout
            return .blocked(.legacyLayout)
        }
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
        changesPending = false
        report.uploadsHeld = !(await uploadsAllowedNow())
        try await DestinationHealth(env: env).refresh()
        _ = try await recovery.resolveInterrupted()
        try await DeferredJobSweeper(env: env).sweep()
        try await hardening.triggers.detectDataAtDestinations()
        try await runStages(.checks, trigger, &report)
        await lane.yieldToCommands()

        // 2. scan, change tracking
        let yieldToCommands: @Sendable () async -> Void = { [lane] in await lane.yieldToCommands() }
        let scan = try await scanner.run(afterBatch: yieldToCommands)
        await lane.yieldToCommands()
        report.scanned = scan.scanned
        if scan.state == .complete {
            switch try await tracker.process() {
            case .upToDate(let processed):
                report.changesProcessed = processed
                needsReconciliation = nil
            case .needsReconciliation(let reason):
                do {
                    try await reconciler.reconcile(reason: reason)
                    needsReconciliation = nil
                } catch {
                    needsReconciliation = reason
                    report.needsReconciliation = reason
                    throw error
                }
            case .scanIncomplete: break
            }
            await lane.yieldToCommands()
            try await finalize.runAfterScan(afterPage: yieldToCommands)
            await lane.yieldToCommands()
            // FR-51: a destination waiting for recovery gets it now, before any upload.
            if await hardening.recovery.hasWork() { try await hardening.recovery.runPending() }
        }
        try await runStages(.changes, trigger, &report)

        // 3–9. repeat while there is progress
        let gate = UploadGate { [self] in await mayStartUpload() }
        while report.rounds < env.tuning.maxCycleIterations {
            try Task.checkCancellation()
            // Pass boundary.
            await lane.yieldToCommands()
            if globallyPaused { return .paused }
            report.rounds += 1
            var progress = 0
            if changesPending { progress += try await pickUpChanges() }
            let uploadsAllowed = await uploadsAllowedNow()
            report.uploadsHeld = !uploadsAllowed
            await resourceGuard.enforce()
            let classified = try await classifier.runPass()
            report.classified += classified.classified
            progress += classified.classified
            try await runStages(.classify, trigger, &report, progress: &progress)
            let exported = try await exporter.runPass()
            report.exported += exported.exported
            progress += exported.exported + exported.skippedByRule
            try await runStages(.export, trigger, &report, progress: &progress)
            // Photos access was lost or the library went away: nothing more can be exported in this
            // cycle; what is already staged still uploads below, then the cycle ends.
            if exported.photosUnavailable { env.log.log(.notice, category: "cycle", "photos unavailable; ending after this pass") }
            try await runStages(.editGate, trigger, &report, progress: &progress)
            if uploadsAllowed {
                let uploaded = try await uploader.runPass(gate: gate)
                report.uploaded += uploaded.uploaded
                report.uploadedByDestination.merge(uploaded.perDestination, uniquingKeysWith: +)
                progress += uploaded.uploaded
            }
            for step in [CycleStep.fanOut, .sidecarsAndViews, .moves, .placeNamer] {
                try await runStages(step, trigger, &report, progress: &progress)
            }
            try await staging.releaseUnneeded()
            try await staging.expireIdle()
            if exported.photosUnavailable { break }
            if progress == 0 {
                report.drained = true
                break
            }
        }

        // 10–11
        try await runStages(.cloudIds, trigger, &report)
        try await recordSuccess(report)
        await SyncMilestones(env: env).record(report)
        await publish()
        return .completed(report)
    }

    /// New photos and edits that arrived during the cycle (FR-12). A history that cannot be
    /// replayed is left to the next cycle, which reconciles.
    private func pickUpChanges() async throws -> Int {
        changesPending = false
        guard case .upToDate(let processed) = try await tracker.process() else { return 0 }
        return processed
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

    /// "Last successful sync" (FR-61) means files reached a destination, or nothing waiting at an
    /// active destination is failing: neither its upload nor the export it waits for has a recorded
    /// error. Work the owner's own rules hold back (battery, Low Power Mode, an expensive network, the
    /// backfill rate) has no error and does not count against it. A single file deferred after
    /// repeated failures is reported on its own (deferred and skipped counts), not as a stopped sync.
    private func recordSuccess(_ report: CycleReport) async throws {
        let now = env.clock.now
        try await env.store.write { db in
            if report.uploaded == 0 {
                let failing = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM upload_job j
                    JOIN destination d ON d.id = j.destination_id
                    LEFT JOIN resource r ON r.asset_key = j.asset_key AND r.res_type = j.res_type
                    WHERE j.state IN ('pending', 'uploading') AND d.status = 'active'
                      AND (j.last_error IS NOT NULL OR (r.last_error IS NOT NULL AND NOT EXISTS (
                            SELECT 1 FROM asset a JOIN source s ON s.id = a.source_id
                            WHERE a.asset_key = j.asset_key AND s.status = 'offline')))
                    """) ?? 0
                guard failing == 0 else { return }
            }
            try KeyValueRepository.set(db, KeyValueRepository.Key.lastSuccessfulSyncAt, now)
        }
    }
}
