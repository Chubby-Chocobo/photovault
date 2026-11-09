import Foundation

/// Naming state of a promoted day folder (spec 8.2 `day_stat.place_state`).
public enum PlaceState: String, Codable, Sendable, CaseIterable {
    case pending, waitingGeocode, named, unnamed
}

/// Row of `day_stat` (camera branch only).
public struct DayStat: Hashable, Codable, Sendable {
    public var day: ArchiveDay
    public var count: Int
    public var promoted: Bool
    public var promotedAt: Date?
    /// `<iso>|<administrativeArea en>` key when named.
    public var placeKey: String?
    /// Display place name in the configured language.
    public var placeName: String?
    public var placeState: PlaceState

    public init(day: ArchiveDay, count: Int = 0, promoted: Bool = false, promotedAt: Date? = nil,
                placeKey: String? = nil, placeName: String? = nil, placeState: PlaceState = .pending) {
        self.day = day
        self.count = count
        self.promoted = promoted
        self.promotedAt = promotedAt
        self.placeKey = placeKey
        self.placeName = placeName
        self.placeState = placeState
    }
}

/// Structured reverse-geocoding result.
public struct GeoPlace: Hashable, Codable, Sendable {
    public var isoCountryCode: String?
    public var country: String?
    public var administrativeArea: String?
    public var locality: String?

    public init(isoCountryCode: String? = nil, country: String? = nil, administrativeArea: String? = nil, locality: String? = nil) {
        self.isoCountryCode = isoCountryCode
        self.country = country
        self.administrativeArea = administrativeArea
        self.locality = locality
    }
}

/// Row of `geo_cache`, kept forever (FR-84).
public struct GeoCacheEntry: Hashable, Codable, Sendable {
    public var cell: GeoCell
    public var locale: String
    public var place: GeoPlace
    public var fetchedAt: Date

    public init(cell: GeoCell, locale: String, place: GeoPlace, fetchedAt: Date) {
        self.cell = cell
        self.locale = locale
        self.place = place
        self.fetchedAt = fetchedAt
    }
}

/// Row of `remote_folder`. Logical paths never contain display names (spec 8.2).
public struct RemoteFolder: Hashable, Codable, Sendable {
    public var destinationId: DestinationID
    public var logicalPath: String
    /// Reserved (Drive) before creation, confirmed after.
    public var remoteId: String?
    public var displayName: String
    /// Whether creation has been confirmed by the destination.
    public var created: Bool
    /// Session in which `trashed` was last verified (FR-47).
    public var verifiedSession: String?

    public init(destinationId: DestinationID, logicalPath: String, remoteId: String? = nil, displayName: String,
                created: Bool = false, verifiedSession: String? = nil) {
        self.destinationId = destinationId
        self.logicalPath = logicalPath
        self.remoteId = remoteId
        self.displayName = displayName
        self.created = created
        self.verifiedSession = verifiedSession
    }
}

public enum MoveOperation: String, Codable, Sendable, CaseIterable {
    case moveFile, renameFolder
}

public enum MoveJobState: String, Codable, Sendable, CaseIterable {
    case pending, inProgress, done, failed
}

/// Row of `move_job`.
public struct MoveJob: Hashable, Codable, Sendable {
    public var id: Int64?
    public var destinationId: DestinationID
    public var operation: MoveOperation
    /// moveFile: the job identity encoded by `MoveJob.subject(for:)`; renameFolder: the logical path.
    public var subject: String
    public var fromValue: String
    public var toValue: String
    public var state: MoveJobState
    public var attempts: Int
    public var lastError: String?
    public var createdAt: Date

    public init(id: Int64? = nil, destinationId: DestinationID, operation: MoveOperation, subject: String,
                fromValue: String, toValue: String, state: MoveJobState = .pending, attempts: Int = 0,
                lastError: String? = nil, createdAt: Date) {
        self.id = id
        self.destinationId = destinationId
        self.operation = operation
        self.subject = subject
        self.fromValue = fromValue
        self.toValue = toValue
        self.state = state
        self.attempts = attempts
        self.lastError = lastError
        self.createdAt = createdAt
    }

    public static let maxAttempts = 8

    public static func subject(for job: JobIdentity) -> String {
        "\(job.assetKey.rawValue)|\(job.resType.rawValue)"
    }
}

/// Drive views (FR-104..106).
public enum ViewKind: String, Codable, Sendable, CaseIterable {
    case byDevice, byPlace, favorites
}

public enum ShortcutState: String, Codable, Sendable, CaseIterable {
    case pending, done, movePending, trashPending, trashed, failed, userRemoved
}

/// Row of `shortcut`.
public struct ShortcutRecord: Hashable, Codable, Sendable {
    public var destinationId: DestinationID
    public var view: ViewKind
    public var assetKey: AssetKey
    public var targetId: String?
    /// Reserved with `generateIds(type: shortcuts)` before creation.
    public var shortcutId: String?
    public var parentLogical: String?
    public var state: ShortcutState
    public var attempts: Int

    public init(destinationId: DestinationID, view: ViewKind, assetKey: AssetKey, targetId: String? = nil,
                shortcutId: String? = nil, parentLogical: String? = nil, state: ShortcutState = .pending, attempts: Int = 0) {
        self.destinationId = destinationId
        self.view = view
        self.assetKey = assetKey
        self.targetId = targetId
        self.shortcutId = shortcutId
        self.parentLogical = parentLogical
        self.state = state
        self.attempts = attempts
    }
}

/// `device_group`: deterministic id + owner-editable display name (FR-104).
public struct DeviceGroup: Hashable, Codable, Sendable {
    public var groupId: String
    public var displayName: String

    public init(groupId: String, displayName: String) {
        self.groupId = groupId
        self.displayName = displayName
    }
}

/// `device_model`: normalized `make|model` → group.
public struct DeviceModel: Hashable, Codable, Sendable {
    public var makeModelKey: String
    public var groupId: String

    public init(makeModelKey: String, groupId: String) {
        self.makeModelKey = makeModelKey
        self.groupId = groupId
    }
}

/// `view_folder_group`: display names of view grouping levels.
public struct ViewFolderGroup: Hashable, Codable, Sendable {
    public var view: ViewKind
    public var groupKey: String
    public var displayName: String

    public init(view: ViewKind, groupKey: String, displayName: String) {
        self.view = view
        self.groupKey = groupKey
        self.displayName = displayName
    }
}

public enum ActivityKind: String, Codable, Sendable, CaseIterable {
    case renamed, moved, missingFile, statusChanged, recovered, notice
    /// Routine progress: files uploaded in a sync, a backfill finished.
    case milestone
}

/// Row of `activity` (FR-63, newest 500 kept). Never holds secrets, file names or coordinates.
public struct ActivityEvent: Hashable, Codable, Sendable {
    public var id: Int64?
    public var at: Date
    public var kind: ActivityKind
    public var destinationId: DestinationID?
    public var assetKey: AssetKey?
    public var message: String

    public init(id: Int64? = nil, at: Date, kind: ActivityKind, destinationId: DestinationID? = nil,
                assetKey: AssetKey? = nil, message: String) {
        self.id = id
        self.at = at
        self.kind = kind
        self.destinationId = destinationId
        self.assetKey = assetKey
        self.message = message
    }

    public static let retainedCount = 500
}

/// Scan progress stored in `kv` (FR-10).
public enum ScanState: String, Codable, Sendable, CaseIterable {
    case notStarted, running, complete
}
