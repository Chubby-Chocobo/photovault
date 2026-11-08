import Foundation
import PhotoVaultCore

// MARK: Owner-facing types

/// The owner's answer to a missing or trashed Drive root (FR-47).
public enum RootProblemChoice: Sendable, Equatable {
    /// "Tôi đã khôi phục": the engine checks the root again.
    case ownerRestored
    /// "Upload lại vào thư mục mới": a new, empty root is created and everything is queued again.
    case uploadToNewRoot(name: String)
}

public enum RootProblemError: Error, Equatable, Sendable {
    case notRootProblem
    case stillMissing
    case stillTrashed
    case unsupported
}

public struct RecoveryStats: Sendable, Equatable {
    /// Backup files an independent walk of the root found.
    public var found = 0
    /// Files matched to an asset (media and sidecars).
    public var matched = 0
    /// Files that stay untouched because nothing matched them.
    public var unmatched = 0
    public var folders = 0
    public var shortcuts = 0
    /// Matched local files whose size differs from the sidecar: marked `missingRemote`.
    public var suspect = 0

    public init() {}
}

public enum RecoveryBlocker: String, Sendable, Equatable {
    case scanIncomplete, cloudIdsPending, destinationUnavailable, unknownDestination, alreadyRunning
}

public enum RecoveryOutcome: Sendable, Equatable {
    case recovered(RecoveryStats)
    /// The root has content but little of it matched (zero-match guard): the destination stays
    /// `paused(recovering)` until the owner decides.
    case needsOwnerDecision(RecoveryStats)
    case notReady(RecoveryBlocker)
}

/// Something only the owner can settle; the UI lists these (FR-47, 8.15).
public enum OwnerDecision: Sendable, Equatable, Hashable {
    case rootMissing(DestinationID)
    case rootTrashed(DestinationID)
    case folderTrashed(DestinationID)
    /// Files the integrity check could not find; re-upload only after confirmation (T20).
    case integrityMissing(DestinationID, count: Int)
    case recoveryNeedsDecision(DestinationID)

    public var destinationId: DestinationID {
        switch self {
        case .rootMissing(let id), .rootTrashed(let id), .folderTrashed(let id), .recoveryNeedsDecision(let id): id
        case .integrityMissing(let id, _): id
        }
    }
}

public struct IntegrityReport: Sendable, Equatable {
    /// Files compared with the database.
    public var checked = 0
    public var missing = 0
    public var sizeMismatch = 0
    public var hashMismatch = 0
    /// Files whose bytes were read again (local sample).
    public var hashed = 0
    /// Shortcuts the owner deleted (kept as `userRemoved`).
    public var shortcutsRemoved = 0
    /// Shortcuts the app made but the database does not know, now trashed.
    public var shortcutsTrashed = 0
    public var failedMoves = 0
    /// Files found missing per destination.
    public var missingByDestination: [DestinationID: Int] = [:]

    public init() {}

    public var totalProblems: Int { missing + sizeMismatch + hashMismatch }

    mutating func add(_ other: IntegrityReport) {
        checked += other.checked
        missing += other.missing
        sizeMismatch += other.sizeMismatch
        hashMismatch += other.hashMismatch
        hashed += other.hashed
        shortcutsRemoved += other.shortcutsRemoved
        shortcutsTrashed += other.shortcutsTrashed
        failedMoves += other.failedMoves
        missingByDestination.merge(other.missingByDestination, uniquingKeysWith: +)
    }
}

/// Why a cycle ended early. Messages are not kept: only the error type (NFR-06).
public struct CycleFailure: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case photos, destination, database, engine, other
    }

    public var source: Source
    public var errorType: String

    public init(source: Source, errorType: String) {
        self.source = source
        self.errorType = errorType
    }
}

// MARK: Local destination content

/// What the engine needs to read from a local or NAS destination beyond the `Destination`
/// contract: the sidecar files (recovery strategy 2), the SHA-256 of a file (verification) and the
/// archive timezone stored in `.photovault/destination.json`. The composition root provides the
/// implementation over the folder's security-scoped access.
public protocol LocalContentReading: Sendable {
    /// Bytes of a small file (a sidecar) at a path relative to the root; nil when it does not exist.
    func readSidecar(destination: DestinationID, path: String) async throws -> Data?
    /// SHA-256 of the file at a path relative to the root; nil when it does not exist.
    func sha256(destination: DestinationID, path: String) async throws -> String?
    /// `archiveTimezone` of `.photovault/destination.json`, nil when there is no marker.
    func archiveTimezone(destination: DestinationID) async throws -> String?
}

public typealias SidecarReading = LocalContentReading
