import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// Owner actions and recovery of phase 10: reconciliation, recovery from a destination, integrity
/// checks, root problems and retries. The UI is written against these names.
extension SyncCoordinator {
    // MARK: Reconciliation (FR-13)

    /// "Đối chiếu lại": lists the whole library again, then runs a cycle so what is new is uploaded.
    /// Throws when the scan is not complete or Photos refuses.
    public func runReconciliation() async throws {
        try await hardening.reconciler.reconcile(reason: .requested)
        needsReconciliation = nil
        await publish()
        _ = await run(trigger: .manual)
    }

    // MARK: Integrity (FR-47, FR-76)

    /// "Kiểm tra ngay": one destination or all. Missing files become `missingRemote`; nothing is
    /// uploaded again until `confirmReupload`.
    public func runIntegrityCheck(_ id: DestinationID?) async throws -> IntegrityReport {
        let report = try await hardening.integrity.run(id)
        await publish()
        return report
    }

    /// The owner agreed to upload the missing files of a destination again (T20).
    public func confirmReupload(_ id: DestinationID) async throws {
        try await hardening.integrity.confirmReupload(id)
        await publish()
    }

    // MARK: Retries

    /// Deferred jobs go back to `pending` now instead of after 24 hours.
    public func retryDeferred(_ id: DestinationID?) async throws {
        try await hardening.retry.retryDeferred(id)
        await publish()
    }

    /// Skipped jobs go back to `pending`; a known remote file is reused, never uploaded twice.
    public func retrySkipped(_ id: DestinationID?) async throws {
        try await hardening.retry.retrySkipped(id)
        await publish()
    }

    // MARK: Root problems (FR-47)

    /// "Khôi phục giúp tôi": untrashes the root and the folders the app created.
    public func untrashAppItems(_ id: DestinationID) async throws {
        try await hardening.roots.untrashAppItems(id)
        await publish()
    }

    /// The owner's answer to a missing or trashed root. The engine never recreates a root by itself.
    public func resolveRootProblem(_ id: DestinationID, choice: RootProblemChoice) async throws {
        try await hardening.roots.resolve(id, choice: choice)
        await publish()
    }

    // MARK: Recovery (FR-51)

    /// The owner reuses an existing root (`pvRoot=1`) or re-adds a NAS folder that has
    /// `destination.json` (`rootId` is ignored for a local destination). The destination waits for
    /// recovery, which runs in the first cycle after the scan is complete.
    public func adoptExistingRoot(_ id: DestinationID, rootId: String) async throws {
        try await hardening.triggers.adoptExistingRoot(id, rootId: rootId)
        await publish()
    }

    /// FR-08, after the owner confirmed: the Drive root (and perhaps the account) changed. The old
    /// location's state is dropped. A root that has content is recovered; an empty one is filled.
    public func changeDriveRoot(
        _ id: DestinationID, rootId: String, rootName: String, account: DriveAccount? = nil, rootHasContent: Bool
    ) async throws {
        try await hardening.triggers.changeDriveRoot(id, rootId: rootId, rootName: rootName, account: account, rootHasContent: rootHasContent)
        await publish()
    }

    /// The owner asks for recovery now. Needs a complete scan; otherwise `.notReady`.
    public func startRecovery(_ id: DestinationID) async throws -> RecoveryOutcome {
        let outcome = try await hardening.recovery.recover(id)
        if case .recovered = outcome { _ = await run(trigger: .manual) }
        await publish()
        return outcome
    }

    /// After `RecoveryOutcome.needsOwnerDecision`: the owner accepts that nothing at the
    /// destination is used. Everything is queued per scope; files already there may be uploaded again.
    public func proceedWithoutRecovery(_ id: DestinationID) async throws {
        try await hardening.recovery.proceedWithoutRecovery(id)
        await publish()
    }

    // MARK: Owner decisions

    /// Everything waiting for the owner: root problems, trashed folders, missing files, doubtful recovery.
    public func pendingOwnerDecisions() async -> [OwnerDecision] {
        await hardening.pendingOwnerDecisions()
    }
}
