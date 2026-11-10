import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

// MARK: Crash injection

struct SimulatedCrash: Error, EngineAbort { var point: String }

extension FakeDestination.CrashAfterEffect: EngineAbort {}

/// Throws `SimulatedCrash` the first time `armed` is reached.
final class CrashInjector: FaultInjecting, @unchecked Sendable {
    private let lock = NSLock()
    private var armed: CrashPoint?
    private var reached: [CrashPoint] = []
    private var hook: (@Sendable (CrashPoint) throws -> Void)?

    func arm(_ point: CrashPoint?) { lock.withLock { armed = point } }
    /// Runs `body` every time a point is reached (to change state mid-flight).
    func onReach(_ body: (@Sendable (CrashPoint) throws -> Void)?) { lock.withLock { hook = body } }
    var visited: [CrashPoint] { lock.withLock { reached } }

    func reach(_ point: CrashPoint) throws {
        let fire = lock.withLock { () -> Bool in
            reached.append(point)
            if armed == point {
                armed = nil
                return true
            }
            return false
        }
        if fire { throw SimulatedCrash(point: point.rawValue) }
        let body = lock.withLock { hook }
        try body?(point)
    }
}

// MARK: Photos wrapper

/// Forwards to `FakePhotosSource` and lets a test observe or override exports and header reads.
final class ProbePhotosSource: PhotosSource, @unchecked Sendable {
    let inner: FakePhotosSource
    private let lock = NSLock()
    private var running = 0
    private(set) var maxConcurrent = 0
    var beforeExport: (@Sendable (String, ResourceType, ExportControl) async throws -> Void)?
    private var mappingBatchSizes: [Int] = []
    private var mappedIds: [String] = []
    private var adjustmentIds: [String] = []
    var failFetch: (any Error)?
    /// Runs before every page of the library scan is fetched.
    var onFetch: (@Sendable () async -> Void)?
    var headerOverride: (@Sendable (String, URL, ExportControl) async throws -> HeaderResult)?

    init(_ inner: FakePhotosSource) { self.inner = inner }

    var authorization: PhotosAuthorization = .authorized
    func authorizationStatus() -> PhotosAuthorization { authorization }
    func requestAuthorization() async -> PhotosAuthorization { await inner.requestAuthorization() }
    func currentChangeToken() async throws -> ChangeToken { try await inner.currentChangeToken() }
    func fetchAllAssets(after cursor: AssetCursor?, limit: Int) async throws -> AssetPage {
        if let failFetch { throw failFetch }
        await onFetch?()
        return try await inner.fetchAllAssets(after: cursor, limit: limit)
    }
    func assets(localIds: [String]) async throws -> [AssetSnapshot] { try await inner.assets(localIds: localIds) }
    func totalAssetCount() async throws -> Int { try await inner.totalAssetCount() }
    func fetchPersistentChanges(since token: ChangeToken) async throws -> [PersistentChange] { try await inner.fetchPersistentChanges(since: token) }
    func cloudIdentifierMappings(localIds: [String]) async throws -> [String: String] {
        lock.withLock { mappingBatchSizes.append(localIds.count); mappedIds += localIds }
        return try await inner.cloudIdentifierMappings(localIds: localIds)
    }

    var cloudMappingBatches: [Int] { lock.withLock { mappingBatchSizes } }
    /// Every local id the cloud-id backfill asked about.
    var cloudMappingRequests: [String] { lock.withLock { mappedIds } }
    var adjustmentHashRequests: [String] { lock.withLock { adjustmentIds } }
    func localIdentifierMappings(cloudIds: [String]) async throws -> [String: String] { try await inner.localIdentifierMappings(cloudIds: cloudIds) }
    func albums() async throws -> [AlbumSnapshot] { try await inner.albums() }
    func adjustmentDataHash(localId: String) async throws -> String? {
        lock.withLock { adjustmentIds.append(localId) }
        return try await inner.adjustmentDataHash(localId: localId)
    }

    func exportResource(localId: String, type: ResourceType, to destination: URL, control: ExportControl) async throws -> ExportedFile {
        lock.withLock {
            running += 1
            maxConcurrent = max(maxConcurrent, running)
        }
        defer { lock.withLock { running -= 1 } }
        if let beforeExport { try await beforeExport(localId, type, control) }
        return try await inner.exportResource(localId: localId, type: type, to: destination, control: control)
    }

    func readClassificationHeader(localId: String, type: ResourceType, spillTo: URL, control: ExportControl) async throws -> HeaderResult {
        if let headerOverride { return try await headerOverride(localId, spillTo, control) }
        return try await inner.readClassificationHeader(localId: localId, type: type, spillTo: spillTo, control: control)
    }
}

/// Staged test files start with the asset's local id, so ids starting with `sony` read as another camera.
struct StubMetadataReader: MetadataReading {
    func metadata(of file: URL, uti: String, mediaType: MediaType) -> CaptureMetadata {
        // Staged files have no extension: without the resource's UTI a real reader finds nothing.
        guard !uti.isEmpty else { return .empty }
        let head = (try? Data(contentsOf: file)).map { String(decoding: $0.prefix(8), as: UTF8.self) } ?? ""
        if head.hasPrefix("l:sonylow") || head.hasPrefix("sonylow") {
            return CaptureMetadata(make: "SONY", model: "ILCE-7M4", lensModel: "fe 24-70")
        }
        if head.hasPrefix("l:sony") || head.hasPrefix("sony") {
            return CaptureMetadata(make: "SONY", model: "ILCE-7M4", lensModel: "FE 24-70")
        }
        return CaptureMetadata(make: "Apple", model: "iPhone 15", lensModel: "Wide")
    }
}

// MARK: Harness

let utc = TimeZone(identifier: "UTC")!
let camera = CaptureMetadata(make: "Apple", model: "iPhone 15")

/// A complete engine over a real Store, the fake Photos library and fake destinations.
final class Harness: @unchecked Sendable {
    var store: Store
    let fakePhotos = FakePhotosSource()
    let photos: ProbePhotosSource
    let clock = TestClock()
    let disk = FakeDiskSpace()
    let system = FakeSystemConditions()
    let log = RecordingLogSink()
    let injector = CrashInjector()
    let geocoder = FakeGeocoder()
    let root: URL
    let drive = FakeDestination(id: .googleDrive, reservesIds: true)
    let nasId = DestinationID.local()
    let nas: FakeDestination
    var tuning: EngineTuning
    var env: EngineEnvironment
    var coordinator: SyncCoordinator
    /// Reads sidecars and hashes of local destinations (recovery); nil like a production build without it.
    var localContent: (any LocalContentReading)?
    /// Content sources shared by every engine the harness builds (Photos is always registered).
    var sources: SourceRegistry
    private(set) var organizationEnabled: Bool
    /// Replace the fake destinations of the same id in every registry the harness builds.
    var overrides: [any Destination] = []

    /// - Parameter organization: leave sidecars, views and place names at their defaults; the
    ///   upload-pipeline tests switch them off so they only see the backup files.
    init(store: Store? = nil, organization: Bool = false, tuning customTuning: ((inout EngineTuning) -> Void)? = nil) async throws {
        self.store = try store ?? Store.inMemory()
        organizationEnabled = organization
        photos = ProbePhotosSource(fakePhotos)
        sources = SourceRegistry(photos: photos)
        root = try TestFiles.temporaryDirectory("engine")
        nas = FakeDestination(id: nasId, reservesIds: false)
        var t = EngineTuning()
        t.sleep = { _ in }
        t.classifyBatchSize = 10
        customTuning?(&t)
        tuning = t
        let registry = DestinationRegistry([drive, nas])
        env = try await Self.makeEnv(self.store, photos, clock, disk, system, log, injector, root, registry, t, geocoder, sources: sources)
        coordinator = SyncCoordinator(env: env)
        if !organization {
            try await switchOrganizationOff()
        }
    }

    /// Sidecars, views and place names off: the upload-pipeline tests only look at the backup files.
    func switchOrganizationOff() async throws {
        try await env.settings.update { settings in
            settings.sidecarJsonEnabled = false
            settings.sidecarXmpEnabled = false
            settings.viewByDeviceEnabled = false
            settings.viewByPlaceEnabled = false
            settings.viewFavoritesEnabled = false
        }
    }

    static func makeEnv(
        _ store: Store, _ photos: ProbePhotosSource, _ clock: TestClock, _ disk: FakeDiskSpace, _ system: FakeSystemConditions,
        _ log: RecordingLogSink, _ injector: CrashInjector, _ root: URL, _ registry: DestinationRegistry, _ tuning: EngineTuning,
        _ geocoder: FakeGeocoder, _ localContent: (any LocalContentReading)? = nil, sources: SourceRegistry? = nil
    ) async throws -> EngineEnvironment {
        EngineEnvironment(
            store: store, photos: photos, destinations: registry, metadataReader: StubMetadataReader(),
            utiResolver: FakeUTIResolver(), clock: clock, disk: disk, system: system, log: log,
            stagingDirectory: root.appendingPathComponent("staging"), containerDirectory: root,
            settings: try SettingsStore(store: store, defaultTimeZone: utc), tuning: tuning, faults: injector, geocoder: geocoder,
            localContent: localContent, sources: sources)
    }

    /// Emulates a process restart: every in-memory object is rebuilt over the same database,
    /// staging directory and destinations.
    func restart() async throws {
        env = try await Self.makeEnv(store, photos, clock, disk, system, log, injector, root, makeRegistry(), tuning, geocoder, localContent, sources: sources)
        coordinator = SyncCoordinator(env: env)
    }

    func makeRegistry() -> DestinationRegistry { DestinationRegistry([drive, nas] + overrides) }

    var staging: URL { root.appendingPathComponent("staging") }

    // MARK: Destinations

    func addDrive(scope: ScopeMode = .full, rules: DestinationRules = .everything) throws {
        let record = DestinationRecord(
            id: .googleDrive, displayName: "Drive", statusSince: clock.now, scope: scope, rules: rules,
            config: DestinationConfig(driveRootId: "root"), createdAt: clock.now)
        try store.write { db in _ = try DestinationRepository.add(db, record, now: self.clock.now) }
    }

    func addNAS(scope: ScopeMode = .full, rules: DestinationRules = .everything) throws {
        let record = DestinationRecord(
            id: nasId, displayName: "NAS", statusSince: clock.now, scope: scope, rules: rules, createdAt: clock.now)
        try store.write { db in _ = try DestinationRepository.add(db, record, now: self.clock.now) }
    }

    func updateDestination(_ id: DestinationID, _ change: @Sendable (inout DestinationRecord) -> Void) throws {
        try store.write { db in
            var record = try #require(try DestinationRepository.fetch(db, id: id))
            change(&record)
            try DestinationRepository.save(db, record)
        }
    }

    func update(_ change: @escaping @Sendable (inout GlobalSettings) -> Void) async throws {
        try await env.settings.update(change)
    }

    func baseline(_ ids: DestinationID...) async throws {
        try await coordinator.beginBaseline(destinations: ids)
    }

    // MARK: Library

    func snapshot(
        _ id: String, daysAgo: Double = 1, type: MediaType = .image, subtypes: MediaSubtypes = [], raw: Bool = false,
        extra: [ResourceDescriptor] = [], hidden: Bool = false, burst: String? = nil, pick: Bool = true, cloud: String? = nil,
        location: GeoPoint? = nil
    ) -> AssetSnapshot {
        let primary = type == .video
            ? ResourceDescriptor(type: .video, uti: "com.apple.quicktime-movie", originalFilename: "MOV_\(id).MOV", isRaw: false)
            : raw ? ResourceDescriptor(type: .photo, uti: "com.sony.arw-raw-image", originalFilename: "DSC_\(id).ARW", isRaw: true)
            : ResourceDescriptor(type: .photo, uti: "public.heic", originalFilename: "IMG_\(id).HEIC", isRaw: false)
        return AssetSnapshot(
            localId: id, cloudId: cloud, mediaType: type, subtypes: subtypes,
            creationDate: clock.now.addingTimeInterval(-daysAgo * 86_400), isHidden: hidden, burstIdentifier: burst,
            burstIsPick: pick, location: location, resources: [primary] + extra)
    }

    /// Adds a camera-looking asset (header read finds Make/Model).
    func add(_ snapshot: AssetSnapshot, camera isCamera: Bool = true, recordChange: Bool = true) async {
        await fakePhotos.add(snapshot, header: isCamera ? camera : .empty, recordChange: recordChange)
    }

    // MARK: Running

    @discardableResult
    func run(_ trigger: SyncTrigger = .manual) async -> CycleOutcome { await coordinator.run(trigger: trigger) }

    func jobs() throws -> [UploadJob] {
        try store.read { db in
            try [JobState.pending, .uploading, .done, .deferred, .skipped, .cancelled, .missingRemote].flatMap { try JobRepository.fetch(db, state: $0) }
        }
    }

    func jobs(_ state: JobState, destination: DestinationID? = nil) throws -> [UploadJob] {
        try store.read { db in try JobRepository.fetch(db, state: state, destinationId: destination) }
    }

    @discardableResult
    func write<T>(_ body: (Database) throws -> T) throws -> T { try store.write(body) }
    func read<T>(_ body: (Database) throws -> T) throws -> T { try store.read(body) }

    func assetCount() throws -> Int { try store.read { db in try AssetRepository.count(db) } }
    func aliases(of key: AssetKey) throws -> [String] { try store.read { db in try AssetRepository.aliases(db, of: key).map(\.alias) } }
    func changeToken() throws -> Data? { try store.read { db in try KeyValueRepository.data(db, KeyValueRepository.Key.changeToken) } }
    func scanState() throws -> ScanState { try store.read { db in try KeyValueRepository.scanState(db) } }

    func dayStat(_ day: ArchiveDay) throws -> DayStat? { try store.read { db in try DayStatRepository.fetch(db, day: day) } }

    func asset(_ key: AssetKey) throws -> AssetRecord? { try store.read { db in try AssetRepository.fetch(db, key: key) } }

    func stagingFiles() -> [String] {
        let walker = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: [.isRegularFileKey])
        return (walker?.compactMap { ($0 as? URL).flatMap { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true ? $0.path : nil } }) ?? []
    }

    func fileNames(_ destination: FakeDestination) async -> [String] { await destination.files.map(\.name).sorted() }
}

// MARK: Destination wrapper

/// Forwards to a `FakeDestination`; can corrupt the reported hash and measures concurrency.
final class WrappedDestination: Destination, @unchecked Sendable {
    let inner: FakeDestination
    private let lock = NSLock()
    private var corruptUploads = 0
    private var corruptReplaces = 0
    private var running = 0
    private(set) var maxConcurrentUploads = 0
    /// Runs before every `replaceContent` reaches the destination (a mid-flight owner action).
    nonisolated(unsafe) var beforeReplace: (@Sendable () async -> Void)?
    /// Runs when an upload reaches the destination, before anything is written; may throw (cancellation).
    nonisolated(unsafe) var beforeUpload: (@Sendable (UploadRequest) async throws -> Void)?
    /// Runs when the destination is listed (an integrity check); receives the uploads running at that moment.
    nonisolated(unsafe) var onList: (@Sendable (Int) -> Void)?
    /// When set, every listing records `enter` and `exit` here and takes `listDuration` in between.
    nonisolated(unsafe) var listEvents: Box<[String]>?
    nonisolated(unsafe) var listDuration: UInt64 = 0
    private var uploadedNameLog: [String] = []
    var uploadedNames: [String] { lock.withLock { uploadedNameLog } }
    var uploadsRunning: Int { lock.withLock { running } }

    init(_ inner: FakeDestination) { self.inner = inner }

    func corrupt(uploads: Int, replaces: Int) { lock.withLock { corruptUploads = uploads; corruptReplaces = replaces } }

    var id: DestinationID { inner.id }
    var capabilities: DestinationCapabilities { inner.capabilities }
    private var availabilityCount = 0
    /// How often the destination's availability was asked; the cycle asks once per run.
    var availabilityChecks: Int { lock.withLock { availabilityCount } }
    func checkAvailability() async -> DestinationStatus {
        lock.withLock { availabilityCount += 1 }
        return await inner.checkAvailability()
    }
    func reserveIds(count: Int, kind: ReservedIdKind) async throws -> [String] { try await inner.reserveIds(count: count, kind: kind) }
    func ensureFolder(_ request: FolderRequest) async throws -> RemoteFolderRef { try await inner.ensureFolder(request) }

    func upload(_ request: UploadRequest, onSession: @Sendable (SessionCheckpoint) async throws -> Void) async throws -> UploadResult {
        lock.withLock {
            running += 1
            maxConcurrentUploads = max(maxConcurrentUploads, running)
        }
        defer { lock.withLock { running -= 1 } }
        for _ in 0..<10 { await Task.yield() }
        try await beforeUpload?(request)
        var result = try await inner.upload(request, onSession: onSession)
        lock.withLock { uploadedNameLog.append(request.fileName) }
        if lock.withLock({ () -> Bool in
            guard corruptUploads > 0 else { return false }
            corruptUploads -= 1
            return true
        }) { result.verifiedHash = "bad" }
        return result
    }

    func resumeUpload(_ request: UploadRequest, session: SessionCheckpoint, onSession: @Sendable (SessionCheckpoint) async throws -> Void) async throws -> UploadResult {
        try await inner.resumeUpload(request, session: session, onSession: onSession)
    }

    func probe(remoteId: String) async throws -> RemoteItem? { try await inner.probe(remoteId: remoteId) }

    func replaceContent(remoteId: String, _ request: UploadRequest) async throws -> UploadResult {
        await beforeReplace?()
        var result = try await inner.replaceContent(remoteId: remoteId, request)
        if lock.withLock({ () -> Bool in
            guard corruptReplaces > 0 else { return false }
            corruptReplaces -= 1
            return true
        }) { result.verifiedHash = "bad" }
        return result
    }

    func move(remoteId: String, name: String, from: RemoteFolderRef, to: RemoteFolderRef) async throws -> RemoteItem {
        try await inner.move(remoteId: remoteId, name: name, from: from, to: to)
    }

    func renameFolder(_ folder: RemoteFolderRef, newName: String) async throws -> RemoteFolderRef { try await inner.renameFolder(folder, newName: newName) }
    func list(under folder: RemoteFolderRef?) -> AsyncThrowingStream<RemoteItem, any Error> {
        onList?(uploadsRunning)
        guard let events = listEvents else { return inner.list(under: folder) }
        let duration = listDuration
        let source = inner.list(under: folder)
        return AsyncThrowingStream { continuation in
            let task = Task {
                events.mutate { $0.append("enter") }
                try? await Task.sleep(nanoseconds: duration)
                do {
                    for try await item in source { continuation.yield(item) }
                    events.mutate { $0.append("exit") }
                    continuation.finish()
                } catch {
                    events.mutate { $0.append("exit") }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func quota() async throws -> Quota? { try await inner.quota() }
}

extension Harness {
    /// Replaces the Drive destination in the registry with `wrapper`.
    func useWrapped(_ wrapper: WrappedDestination) async { await env.destinations.add(wrapper) }

    /// Creates a ready staged resource (and its asset) by hand, optionally with a job.
    @discardableResult
    func seedStaged(
        _ id: String, type: ResourceType = .photo, gen: Int = 1, bytes: Int = 10, job: (DestinationID, JobState)? = nil,
        lastUsed: Date? = nil, writeFile: Bool = true
    ) throws -> URL {
        let key = AssetKey.local(id)
        let url = StagingManager(env: env).fileURL(assetKey: key, type: type, generation: gen)
        if writeFile {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes).write(to: url)
        }
        let now = clock.now
        try store.write { db in
            try AssetRepository.upsert(db, AssetRecord(
                assetKey: key, localId: id, creationDate: now, mediaType: .image, category: .camera,
                firstSeenAt: now, lastSeenAt: now), timeZone: utc)
            try ResourceRepository.upsert(db, ResourceRecord(assetKey: key, type: type, originalFilename: "IMG_\(id).HEIC", uti: "public.heic", contentGen: gen))
            try ResourceRepository.beginExport(db, key: key, type: type, generation: gen)
            try ResourceRepository.completeExport(db, key: key, type: type, path: url.path, sizeBytes: Int64(bytes), md5: "m", sha256: "s", now: lastUsed ?? now)
            if let (destination, state) = job {
                var row = UploadJob(destinationId: destination, assetKey: key, resType: type, origin: .incremental, targetGen: gen, updatedAt: now)
                row.state = state
                try JobRepository.save(db, &row)
            }
        }
        return url
    }
}

extension FakePhotosSource {
    func snapshotCreation(_ localId: String) async -> Date? {
        try? await assets(localIds: [localId]).first?.creationDate
    }
}
