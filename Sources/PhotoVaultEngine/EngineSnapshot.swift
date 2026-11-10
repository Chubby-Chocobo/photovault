import Foundation
import PhotoVaultCore

public enum SyncTrigger: String, Sendable, Equatable {
    case launch, wake, networkBack, volumeMounted, photosChanged, timer, manual
}

/// Cycle steps of spec 8.4. Stages injected into the coordinator run after the built-in work of
/// their step.
public enum CycleStep: Int, Sendable, Comparable {
    case checks = 1, changes, classify, export, editGate, fanOut, sidecarsAndViews, moves, placeNamer, cloudIds, publish
    public static func < (lhs: CycleStep, rhs: CycleStep) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A unit of cycle work supplied by a later phase (edit gate, sidecars and views, move worker,
/// place namer, FR-53). Returns true when it did work, which makes the cycle run another round.
public protocol CycleStage: Sendable {
    var step: CycleStep { get }
    func run(trigger: SyncTrigger) async throws -> Bool
}

public struct DestinationSnapshot: Sendable, Equatable {
    public var id: DestinationID
    public var displayName: String
    public var status: DestinationStatus
    public var pending: Int
    public var deferred: Int
    public var skipped: Int
    public var missingRemote: Int
    public var lastSuccessAt: Date?
}

/// Observable engine state for the UI (spec 8.4 step 11).
public struct EngineSnapshot: Sendable, Equatable {
    public enum Overall: Sendable, Equatable {
        case idle, syncing, paused, photosUnauthorized, notBaselined, offline, needsReconciliation
        /// The database holds a backup in the old folder layout; nothing runs until the app starts over.
        case legacyLayout
    }

    public var overall: Overall
    public var scanState: ScanState
    public var destinations: [DestinationSnapshot]
    /// Assets that have backfill jobs, and how many of them are finished.
    public var backfillDoneAssets: Int
    public var backfillTotalAssets: Int
    public var bytesUploaded: Int64
    /// Remaining backfill time estimated from the asset completion rate since observation began.
    public var etaSeconds: TimeInterval?
    public var pending: Int
    public var deferred: Int
    public var skipped: Int
    public var missingRemote: Int
    public var updatedAt: Date
    /// One-time imports, newest first (running ones and finished ones).
    public var imports: [ImportSnapshot] = []
    /// How the last backfill ended; nil until one has. A record, not progress: the menu bar ignores it.
    public var backfillCompletion: BackfillCompletionSummary?
}

/// Progress of one folder import, for Settings and the menu bar.
public struct ImportSnapshot: Sendable, Equatable, Identifiable {
    public var id: SourceID
    public var kind: SourceKind
    /// Cloud account (email) the import reads from. Shown in the app only; never logged.
    public var account: String?
    /// Set when a Mac-folder import reads a Google Drive or Dropbox folder synced to this Mac.
    public var syncedProvider: SyncedCloudProvider?
    /// Why an offline import waits (`signInRequired` when the provider rejected the grant).
    public var statusReason: String?
    /// The folder's name. Shown in the app only; never written to logs or the activity list.
    public var displayName: String
    public var status: SourceStatus
    public var createdAt: Date
    public var finishedAt: Date?
    /// Files found in the folder.
    public var found: Int
    /// Files read and decided on (imported, already backed up, skipped, failed or cancelled).
    public var processed: Int
    public var imported: Int
    public var duplicates: Int
    public var unsupported: Int
    public var failed: Int
    /// Upload jobs of this import that finished, and all that will or did upload (every destination).
    public var filesUploaded: Int
    public var filesTotal: Int

    public var isFinished: Bool { !status.isOpen }

    public init(
        id: SourceID, kind: SourceKind = .localFolder, account: String? = nil, syncedProvider: SyncedCloudProvider? = nil, statusReason: String? = nil,
        displayName: String, status: SourceStatus, createdAt: Date, finishedAt: Date? = nil, found: Int = 0,
        processed: Int = 0, imported: Int = 0, duplicates: Int = 0, unsupported: Int = 0, failed: Int = 0,
        filesUploaded: Int = 0, filesTotal: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.account = account
        self.syncedProvider = syncedProvider
        self.statusReason = statusReason
        self.displayName = displayName
        self.status = status
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.found = found
        self.processed = processed
        self.imported = imported
        self.duplicates = duplicates
        self.unsupported = unsupported
        self.failed = failed
        self.filesUploaded = filesUploaded
        self.filesTotal = filesTotal
    }
}

public enum CycleBlock: Sendable, Equatable {
    case photosUnauthorized, notBaselined
    /// The database holds a backup in the old `YYYY/MM` layout; the cycle does nothing.
    case legacyLayout
}

public struct CycleReport: Sendable, Equatable {
    public var scanned = 0
    public var changesProcessed = 0
    public var classified = 0
    public var exported = 0
    public var uploaded = 0
    /// Files uploaded per destination in this cycle.
    public var uploadedByDestination: [DestinationID: Int] = [:]
    /// The cycle stopped because nothing was left to do (not the round limit, not lost Photos access).
    public var drained = false
    public var stageWork = 0
    public var rounds = 0
    public var needsReconciliation: ReconciliationReason?
    public var uploadsHeld = false
}

public enum CycleOutcome: Sendable, Equatable {
    case completed(CycleReport)
    /// Another cycle was running; exactly one follow-up cycle will run after it.
    case queued
    case paused
    case blocked(CycleBlock)
    /// The cycle stopped on an error; nothing is lost, the next cycle starts again. Only the error type is kept.
    case failed(CycleFailure)
}
