import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// Live destinations by id; destinations are added and removed while the engine runs (FR-71).
public actor DestinationRegistry {
    private var map: [DestinationID: any Destination] = [:]

    public init(_ destinations: [any Destination] = []) {
        for destination in destinations { map[destination.id] = destination }
    }

    public func add(_ destination: any Destination) { map[destination.id] = destination }
    public func remove(_ id: DestinationID) { map[id] = nil }
    public func destination(for id: DestinationID) -> (any Destination)? { map[id] }
    public var ids: [DestinationID] { map.keys.sorted() }
}

/// Points at which a process death can be injected in tests. Production passes no injector.
public enum CrashPoint: String, CaseIterable, Sendable {
    case afterFolderIdPersisted
    case afterFolderCreated
    case afterFileIdReserved
    case afterFileIdPersisted
    case afterStartUpload
    case afterSessionPersisted
    case afterUploadBeforeCommit
    case afterCommitBeforeRelease
    case afterExportBeforeCommit
    case afterImportInspectBeforeCommit
    case afterImportGroupCommit
}

/// Test seam: `reach` may throw an `EngineAbort` error to emulate the process dying at `point`.
public protocol FaultInjecting: Sendable {
    func reach(_ point: CrashPoint) throws
}

/// Errors that stand for process death. Every engine `catch` rethrows them untouched and writes
/// nothing, so the database stays exactly as a real crash would leave it.
public protocol EngineAbort: Error {}

/// Knobs with the spec defaults; tests shrink them.
public struct EngineTuning: Sendable {
    public var maxConcurrentExports = 2
    public var maxConcurrentUploadsPerDestination = 2
    public var scanBatchSize = 500
    public var classifyBatchSize = 25
    public var exportCheckpointBytes = ExportControl.defaultCheckpointBytes
    /// Staged files not touched for this long, with no transfer running, are released (8.9.3).
    public var stagingIdleExpiry: TimeInterval = 2 * 3600
    public var transientRetries = ErrorClassifier.transientRetries
    public var maxCycleIterations = 100_000
    /// Files of a folder import recorded per transaction while listing.
    public var importListBatch = 500
    /// Whole file groups of a folder import read and ingested per stage run.
    public var importBatchGroups = 100
    /// A stage run stops reading after this many bytes (it always finishes the group it is in).
    public var importBatchBytes: Int64 = 2 * GlobalSettings.GiB
    /// Pause between the exports recovery makes to tell look-alike files apart (FR-51).
    public var recoveryExportInterval: TimeInterval = 2
    /// At most this many look-alike candidates are exported per recovery run.
    public var recoveryExportBudget = 200
    /// Recovered local files whose SHA-256 is verified per cycle.
    public var recoveryVerifyBatch = 25
    /// Waits between in-pass retries; tests replace it with a no-op.
    public var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    public init() {}
}

/// Everything the engine services share.
public struct EngineEnvironment: Sendable {
    public var store: Store
    public var photos: any PhotosSource
    /// Where resource bytes are read from, by `asset.source_id`. Photos is always registered.
    public var sources: SourceRegistry
    public var destinations: DestinationRegistry
    public var metadataReader: any MetadataReading
    public var utiResolver: any UTIResolver
    public var clock: any Clock
    public var disk: any DiskSpaceProvider
    public var system: any SystemConditions
    public var log: any LogSink
    public var layout: any LayoutPolicy
    public var transform: any Transform
    public var stagingDirectory: URL
    public var containerDirectory: URL
    public var settings: SettingsStore
    public var tuning: EngineTuning
    public var faults: (any FaultInjecting)?
    /// Reverse geocoder for place names; nil disables geocoding (FR-85).
    public var geocoder: (any ReverseGeocoding)?
    /// Reads sidecars, hashes and the marker of local destinations; nil limits local recovery to names.
    public var localContent: (any LocalContentReading)?

    public init(
        store: Store, photos: any PhotosSource, destinations: DestinationRegistry, metadataReader: any MetadataReading,
        utiResolver: any UTIResolver, clock: any Clock = SystemClock(), disk: any DiskSpaceProvider,
        system: any SystemConditions, log: any LogSink = NullLogSink(), layout: any LayoutPolicy = DynamicLayout(),
        transform: any Transform = IdentityTransform(), stagingDirectory: URL, containerDirectory: URL,
        settings: SettingsStore, tuning: EngineTuning = EngineTuning(), faults: (any FaultInjecting)? = nil,
        geocoder: (any ReverseGeocoding)? = nil, localContent: (any LocalContentReading)? = nil,
        sources: SourceRegistry? = nil
    ) {
        self.store = store
        self.photos = photos
        self.sources = sources ?? SourceRegistry(photos: photos)
        self.destinations = destinations
        self.metadataReader = metadataReader
        self.utiResolver = utiResolver
        self.clock = clock
        self.disk = disk
        self.system = system
        self.log = log
        self.layout = layout
        self.transform = transform
        self.stagingDirectory = stagingDirectory
        self.containerDirectory = containerDirectory
        self.settings = settings
        self.tuning = tuning
        self.faults = faults
        self.geocoder = geocoder
        self.localContent = localContent
    }

    func reach(_ point: CrashPoint) throws { try faults?.reach(point) }

    func nameBuilder(_ timeZone: TimeZone) -> NameStemBuilder {
        NameStemBuilder(timeZone: timeZone, utiResolver: utiResolver)
    }
}

/// Engine-level failures that are not destination or Photos errors.
public enum EngineError: Error, Equatable, Sendable {
    case notBaselined
    case alreadyRunning
    case unsandboxedBuild
    case invalidState(String)
}
