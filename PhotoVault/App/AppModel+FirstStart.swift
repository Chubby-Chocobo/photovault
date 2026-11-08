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
            firstStart?.failure = ErrorText.message(for: error)
        }
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
    private func waitForScan(_ env: AppEnvironment) async throws {
        while true {
            let snapshot = await env.coordinator.currentSnapshot()
            self.snapshot = snapshot
            if snapshot.scanState == .complete { return }
            try await Task.sleep(for: .seconds(1))
        }
    }

    private func recoverReusedDestinations(_ plan: FirstStartPlan) async throws {
        guard let hardening else { throw EngineError.invalidState("recovery unavailable") }
        var ids: [DestinationID] = []
        if case .reuse = plan.root { ids.append(.googleDrive) }
        if let nas = plan.nas, nas.isReuse { ids.append(nas.destinationId) }
        for id in ids {
            // The engine may already have recovered this destination during a cycle.
            let stillRequired = try await env?.store.read { db in try DestinationRepository.fetch(db, id: id)?.recoveryRequired } ?? nil
            guard stillRequired == true else { continue }
            do {
                let report = try await hardening.startRecovery(id)
                firstStart?.matchedFiles += report.matchedFiles
            } catch RecoveryCommandError.notReady(.alreadyRunning) {
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
