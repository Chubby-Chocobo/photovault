import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Everything phase 10 adds to the engine: FR-53 backfill, reconciliation (FR-13), recovery
/// (FR-51), integrity checks (FR-47, FR-76), root problems and retries. The coordinator owns one.
struct HardeningServices: Sendable {
    let backfill: CloudIdBackfill
    let reconciler: Reconciler
    let recovery: RecoveryService
    let triggers: RecoveryTriggers
    let integrity: IntegrityChecker
    let roots: RootProblemService
    let retry: RetryService
    let stages: [any CycleStage]
    let env: EngineEnvironment

    init(env: EngineEnvironment, uploader: UploadRunner, finalize: FinalizePass, eligibility: EligibilityService,
         extensions: [any JobPlanningExtension], organization: OrganizationServices) {
        self.env = env
        let backfill = CloudIdBackfill(env: env)
        let refresh: @Sendable () async throws -> Void = { try await organization.settingsChanged() }
        let forget: @Sendable (DestinationID) async -> Void = { id in await uploader.forget(id) }
        let recovery = RecoveryService(
            env: env, backfill: backfill, finalize: finalize, eligibility: eligibility, uploader: uploader, afterRecovery: refresh)
        self.backfill = backfill
        self.recovery = recovery
        reconciler = Reconciler(env: env, backfill: backfill, extensions: extensions, afterReconcile: refresh)
        triggers = RecoveryTriggers(env: env, forget: forget)
        integrity = IntegrityChecker(env: env)
        roots = RootProblemService(env: env, forget: forget, enqueue: { id in try await recovery.enqueueRest(id) })
        retry = RetryService(env: env)
        stages = [CloudIdBackfillStage(backfill: backfill), RecoveryVerifyStage(env: env), IntegrityStage(env: env)]
    }

    /// What only the owner can settle (FR-47, 8.15), read from the database.
    func pendingOwnerDecisions() async -> [OwnerDecision] {
        let env = env
        return ((try? await env.store.read { db -> [OwnerDecision] in
            var decisions: [OwnerDecision] = []
            for record in try DestinationRepository.fetchAll(db) {
                switch record.status {
                case .paused(.rootMissing): decisions.append(.rootMissing(record.id))
                case .paused(.rootTrashed): decisions.append(.rootTrashed(record.id))
                case .paused(.folderTrashed): decisions.append(.folderTrashed(record.id))
                default: break
                }
                let missing = try JobRepository.count(db, destinationId: record.id, state: .missingRemote)
                if missing > 0 { decisions.append(.integrityMissing(record.id, count: missing)) }
                let mismatches = try KeyValueRepository.int(db, IntegrityChecker.resultMismatchKey + record.id.rawValue) ?? 0
                if mismatches > 0, try KeyValueRepository.int(db, IntegrityChecker.mismatchDismissedKey + record.id.rawValue) != 1 {
                    decisions.append(.checksumMismatch(record.id, count: mismatches))
                }
                if try KeyValueRepository.int(db, RecoveryService.decisionKey + record.id.rawValue) == 1 {
                    decisions.append(.recoveryNeedsDecision(record.id))
                }
            }
            return decisions
        }) ?? [])
    }
}

extension CycleFailure {
    init(_ error: any Error) {
        let source: Source
        switch error {
        case is PhotosSourceError: source = .photos
        case is DestinationError: source = .destination
        case is DatabaseError, is StoreError: source = .database
        case is EngineError, is RootProblemError: source = .engine
        default: source = .other
        }
        self.init(source: source, errorType: String(describing: type(of: error)))
    }
}
