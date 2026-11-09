import Foundation
import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultDrive
import PhotoVaultEngine
import PhotoVaultStore

/// Everything the owner decided in onboarding, applied when they press "Bắt đầu".
struct FirstStartPlan {
    var identity: GoogleIdentity
    var root: RootChoice
    var timeZone: TimeZone
    var scope: ScopeMode
    var nas: PendingLocalDestination?
}

enum FirstStartError: Error {
    case scanStalled, photosAccessLost

    var message: String {
        switch self {
        case .scanStalled: "Việc quét thư viện không tiến triển trong 30 phút. Kiểm tra quyền Photos rồi thử lại."
        case .photosAccessLost: "PhotoVault mất quyền đọc thư viện Photos giữa chừng. Cấp lại quyền rồi thử lại."
        }
    }
}

struct FirstStartState: Equatable {
    var phases: [OnboardingPhase]
    var current = 0
    var matchedFiles = 0
    var failure: String?
    var finished = false

    var isRunning: Bool { failure == nil && !finished }
}

/// FR-01 step 9: baseline (FR-15), scan (FR-10), recovery (FR-51), then upload. It lives on the model,
/// not on the onboarding window, so closing the window does not interrupt it.
extension AppModel {
    func performFirstStart(_ plan: FirstStartPlan) async {
        guard let env else { return }
        let reuseDrive: Bool = { if case .reuse = plan.root { true } else { false } }()
        let reusesSomething = reuseDrive || (plan.nas?.isReuse ?? false)
        firstStart = FirstStartState(phases: OnboardingPhase.sequence(reusingExistingDestination: reusesSomething))
        do {
            try await env.settings.setArchiveTimeZone(plan.timeZone)
            archiveTimeZone = plan.timeZone
            try await reconcileUnstartedDestinations(plan, env: env)
            try await createDriveDestination(plan, env: env)
            if let nas = plan.nas, !destinations.contains(where: { $0.id == nas.destinationId }) {
                try await commit(nas)
            }
            await refresh()
            try await env.coordinator.beginBaseline(destinations: destinations.map(\.id))
            advanceFirstStart(to: .scan)
            await goLive()
            try await waitForScan(env)
            if reusesSomething {
                advanceFirstStart(to: .restore)
                try await recoverReusedDestinations(plan)
            }
            advanceFirstStart(to: .upload)
            requestSync(.manual)
            firstStart?.finished = true
            env.log.log(.info, category: "onboarding", "first start completed")
        } catch {
            env.log.log(.error, category: "onboarding", "first start failed: \(type(of: error))")
            firstStart?.failure = (error as? FirstStartError)?.message
                ?? (error is CancellationError ? "Đã huỷ." : ErrorText.message(for: error))
        }
    }

    /// A start that failed before the baseline left rows behind; the owner may have changed their
    /// answers since. Rows that no longer match the plan are forgotten (database only: nothing at the
    /// destination is touched) so the plan is applied as chosen; a matching Drive row only takes the
    /// new scope. After the baseline the start is resumed as it was.
    private func reconcileUnstartedDestinations(_ plan: FirstStartPlan, env: AppEnvironment) async throws {
        guard try await env.store.read({ db in try AppQueries.baselineTaken(db) }) == false else { return }
        await refresh()
        if let drive = driveRecord {
            let sameAccount = drive.accountId == plan.identity.sub
            let sameRoot: Bool = switch plan.root {
            case .reuse(let id, _): drive.config.driveRootId == id
            case .createNew(let name): !drive.recoveryRequired && drive.config.driveRootName == RootNameValidator.normalized(name)
            }
            if sameAccount, sameRoot {
                if drive.scope != plan.scope {
                    var updated = drive
                    updated.scope = plan.scope
                    let record = updated
                    try await env.store.write { db in try DestinationRepository.save(db, record) }
                }
            } else {
                await env.coordinator.destinationRemoved(.googleDrive)
                try await env.store.write { db in try DestinationRepository.remove(db, id: .googleDrive) }
                env.log.log(.notice, category: "onboarding", "forgot the Drive destination of an unfinished start")
            }
        }
        for local in localRecords where local.id != plan.nas?.destinationId {
            await env.coordinator.destinationRemoved(local.id)
            try await env.store.write { db in try DestinationRepository.remove(db, id: local.id) }
            env.log.log(.notice, category: "onboarding", "forgot a folder destination of an unfinished start")
        }
        await refresh()
    }

    private func createDriveDestination(_ plan: FirstStartPlan, env: AppEnvironment) async throws {
        // A retry after a failure further down must not create a second root.
        guard !destinations.contains(where: { $0.id == .googleDrive }) else { return }
        let rootId: String
        let rootName: String
        var recoveryRequired = false
        switch plan.root {
        case .createNew(let name):
            let root = try await DriveRootService(drive: env.drive).createRoot(
                name: RootNameValidator.normalized(name), archiveTimeZone: plan.timeZone)
            (rootId, rootName) = (root.remoteId, root.name)
        case .reuse(let id, let name):
            guard hardening != nil else { throw EngineError.invalidState("recovery unavailable") }
            (rootId, rootName) = (id, name)
            recoveryRequired = true
        }
        let now = Date()
        let record = DestinationRecord(
            id: .googleDrive, displayName: "Google Drive", statusSince: now, scope: plan.scope,
            config: DestinationConfig(driveRootId: rootId, driveRootName: rootName),
            accountId: plan.identity.sub, accountEmail: plan.identity.email, recoveryRequired: recoveryRequired, createdAt: now)
        _ = try await env.store.write { db in try DestinationRepository.add(db, record, now: now) }
        await env.drive.setRootId(rootId)
        await env.registry.add(env.drive)
        if recoveryRequired, let hardening { try await hardening.adoptExistingRoot(.googleDrive, rootId: rootId) }
    }

    /// Recovery runs only after the scan is complete (FR-51).
    /// Stops when the task is cancelled, Photos access is lost, or there has been no progress for
    /// `scanStallLimit`. Progress is the number of assets the scan has stored (each batch adds some) or
    /// any change in the engine snapshot; the timestamp and ETA, which move on their own, are left out.
    private func waitForScan(_ env: AppEnvironment) async throws {
        var watchdog = ProgressWatchdog<ScanProgress>(limit: Self.scanStallLimit, now: Date())
        while true {
            try Task.checkCancellation()
            let snapshot = await env.coordinator.currentSnapshot()
            self.snapshot = snapshot
            if snapshot.scanState == .complete { return }
            if snapshot.overall == .photosUnauthorized || env.photos.authorizationStatus().allowsReading == false {
                throw FirstStartError.photosAccessLost
            }
            var stable = snapshot
            stable.updatedAt = .distantPast
            stable.etaSeconds = nil
            let assets = (try? await env.store.read { db in try AssetRepository.count(db) }) ?? -1
            if watchdog.isStalled(ScanProgress(snapshot: stable, assets: assets), now: Date()) { throw FirstStartError.scanStalled }
            try await Task.sleep(for: .seconds(1))
        }
    }

    static let scanStallLimit: TimeInterval = 30 * 60

    private struct ScanProgress: Equatable, Sendable {
        var snapshot: EngineSnapshot
        var assets: Int
    }

    private func recoverReusedDestinations(_ plan: FirstStartPlan) async throws {
        guard let hardening else { throw EngineError.invalidState("recovery unavailable") }
        var ids: [DestinationID] = []
        if case .reuse = plan.root { ids.append(.googleDrive) }
        if let nas = plan.nas, nas.isReuse { ids.append(nas.destinationId) }
        for id in ids {
            // A cycle may have recovered this destination already; the engine then skips it and
            // reports no matches, which leaves the onboarding line without a count.
            do {
                let report = try await hardening.startRecovery(id, onlyIfRequired: true)
                firstStart?.matchedFiles += report.matchedFiles
            } catch RecoveryCommandError.notReady(.alreadyRunning) {
                continue
            } catch RecoveryCommandError.notReady(let blocker) where blocker == .destinationUnavailable || blocker == .cloudIdsPending {
                // The destination stays "recovery required": the sync cycle runs it once it can, and
                // nothing is uploaded there before. The start itself is done.
                showNotice(RecoveryCommandError.notReady(blocker).message + " Khôi phục sẽ tự chạy tiếp.")
                continue
            } catch RecoveryCommandError.needsOwnerDecision {
                // The decision card in the menu bar takes over; the other destinations keep going.
                continue
            }
        }
    }

    private func advanceFirstStart(to phase: OnboardingPhase) {
        guard let index = firstStart?.phases.firstIndex(of: phase) else { return }
        firstStart?.current = index
    }
}
