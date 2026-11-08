import Foundation
import PhotoVaultCore

/// Owner-facing recovery and integrity actions (FR-13, FR-47, FR-51, FR-76). The UI talks only to
/// this protocol, with app-side value types; a separate adapter maps it onto the engine.
protocol HardeningCommands: Sendable {
    /// Settings › Nâng cao › Đối soát: lists the whole Photos library again (FR-13).
    func runReconciliation() async throws
    /// "Kiểm tra ngay": integrity walk of one destination, or of all when nil (FR-76).
    func runIntegrityCheck(_ id: DestinationID?) async throws -> IntegrityCheckSummary
    /// The owner agreed to upload files reported missing again (`missingRemote` -> `pending`).
    func confirmReupload(_ id: DestinationID) async throws
    /// The owner has seen the checksum mismatches of this destination; the card goes away until a new check finds more.
    func dismissChecksumMismatch(_ id: DestinationID) async throws
    /// Puts deferred jobs back in the queue; nil = every destination.
    func retryDeferred(_ id: DestinationID?) async throws
    /// Puts skipped jobs back in the queue; nil = every destination.
    func retrySkipped(_ id: DestinationID?) async throws
    /// "Khôi phục giúp tôi": removes `trashed` from items the app created at this destination.
    func untrashAppItems(_ id: DestinationID) async throws
    /// Finishes a root or folder problem after the owner decided.
    func resolveRootProblem(_ id: DestinationID, choice: RootProblemResolution) async throws
    /// Onboarding / FR-08: use an existing PhotoVault root (`pvRoot=1`) as the destination's root,
    /// recovering state from it before uploads resume.
    func adoptExistingRoot(_ id: DestinationID, rootId: String) async throws
    /// "Khôi phục giúp tôi" in Settings › Nâng cao: rebuilds database state from the destination (FR-51).
    func startRecovery(_ id: DestinationID) async throws -> RecoveryReport
    /// The owner accepts that nothing found at the destination is reused (zero-match guard, 8.15).
    func proceedWithoutRecovery(_ id: DestinationID) async throws
    /// Prompts the engine is waiting on, for the menu bar and the activity window.
    func pendingOwnerDecisions() async -> [OwnerDecisionItem]
}

enum RootProblemResolution: Equatable, Sendable {
    /// The owner restored the folder himself; check it again and continue.
    case ownerRestored
    /// Create a new root with this name, reset the destination and upload everything again (FR-08).
    case uploadToNewRoot(name: String)
}

struct IntegrityCheckSummary: Equatable, Sendable {
    /// Files the destination no longer has, per destination (only destinations with at least one).
    var missingFiles: [DestinationID: Int]
    /// Files whose checksum differs from what was uploaded.
    var checksumMismatches: [DestinationID: Int]

    /// Destinations that could not be reached, so nothing is known about them.
    var skipped: [DestinationID] = []

    var isClean: Bool { missingFiles.isEmpty && checksumMismatches.isEmpty && skipped.isEmpty }
}

struct RecoveryReport: Equatable, Sendable {
    var matchedFiles: Int
    var unmatchedFiles: Int
}

/// A question the engine put to the owner (FR-47, FR-76). Paths are folder names only, never file names.
struct OwnerDecisionItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case rootTrashed(rootName: String)
        case rootMissing(rootName: String)
        /// A folder the app created under the root is in the trash; the engine does not keep its name.
        case folderTrashed
        /// Recovery found content at the destination but matched too little of it (zero-match guard).
        case recoveryNeedsDecision
        case integrityMissing(fileCount: Int, folderHints: [String])
        case checksumMismatch(fileCount: Int)
    }

    var destinationId: DestinationID
    var destinationName: String
    var kind: Kind

    var id: String { destinationId.rawValue + "|" + kindKey }

    private var kindKey: String {
        switch kind {
        case .rootTrashed: "rootTrashed"
        case .rootMissing: "rootMissing"
        case .folderTrashed: "folderTrashed"
        case .recoveryNeedsDecision: "recoveryNeedsDecision"
        case .integrityMissing: "integrityMissing"
        case .checksumMismatch: "checksumMismatch"
        }
    }
}
