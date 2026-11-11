import Foundation
import PhotoVaultCore
import PhotoVaultStore

struct ExportPassResult: Sendable, Equatable {
    var exported = 0
    var failed = 0
    var cancelledForDisk = 0
    var skippedByRule = 0
    /// Set when the guard stopped the pass (critical disk, staging full).
    var blockedBy: DiskGuardBlock?
    /// Set when Photos refused or lost the library; the pass ended early so the cycle re-checks access.
    var photosUnavailable = false
    /// Set when the owner paused or a command waits: the pass ended early and has more to do after the pass boundary.
    var yielded = false
}

/// Step 4 of the cycle (FR-30..34, FR-23, NFR-09). Each resource is exported once for every
/// available destination that needs it. Candidates run incremental > refresh > reupload >
/// backfill, newest first, the primary resource of an asset before its others; at most
/// `maxConcurrentExports` run at once. Only placed assets are exported, so nothing is staged
/// before the placement exists.
actor ExportWorker {
    let env: EngineEnvironment
    let resourceGuard: ResourceGuard
    private let staging: StagingManager
    /// Candidates fetched once and consumed in order; refetched when exhausted, so a pass over a
    /// large backlog does not repeat the ranking query for every export.
    var queue: [Candidate] = []
    /// Set by a failure that says Photos itself is unusable; ends the running pass.
    private var photosLost = false
    /// Sources whose exports were put off for the owner to sign in during this pass; their candidates still in
    /// `queue` are skipped, so the provider is asked once and not once per file.
    var signInDeferred = Set<SourceID>()
    /// A resource that failed without a reason of its own waits this long before it is picked again.
    static let transientRetryDelay: TimeInterval = 60

    /// The owner's pause and import cancels: a paused pass starts no further export, and the files of an import whose
    /// cancel was asked are not read again.
    let interrupts: ImportInterrupts
    /// True while an owner command waits for the lane: the pass starts no further export.
    private let commandWaiting: @Sendable () async -> Bool

    init(
        env: EngineEnvironment, resourceGuard: ResourceGuard, staging: StagingManager, interrupts: ImportInterrupts = ImportInterrupts(),
        commandWaiting: @escaping @Sendable () async -> Bool = { false }
    ) {
        self.env = env
        self.resourceGuard = resourceGuard
        self.staging = staging
        self.interrupts = interrupts
        self.commandWaiting = commandWaiting
    }

    struct Candidate: Sendable {
        var row: EngineQueries.ExportRow
        var isPrimary: Bool
        var id: String { "\(row.key.rawValue)|\(row.type.rawValue)" }
    }

    struct Started: Sendable {
        var id: String
        var permit: ExportPermit
        var asset: AssetRecord
        var resource: ResourceRecord
        var needing: [DestinationRecord]
        var isPrimary: Bool
        var settings: GlobalSettings
        /// Every job waiting for this file is a backfill job.
        var isBackfill = false
    }

    private enum Outcome: Sendable {
        case exported(String), failed(String), cancelledForDisk(String), skippedByRule(String)
        var id: String {
            switch self {
            case .exported(let id), .failed(let id), .cancelledForDisk(let id), .skippedByRule(let id): id
            }
        }
    }

    func runPass() async throws -> ExportPassResult {
        try await revisitTooLarge()
        queue = []
        photosLost = false
        signInDeferred = []
        var result = ExportPassResult()
        var inFlight = Set<String>()
        var held = Set<String>()
        // Candidates that failed in this pass are not picked again until the next pass.
        var failed = Set<String>()
        var stop = false
        let limit = max(1, env.tuning.maxConcurrentExports)
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            while true {
                try Task.checkCancellation()
                while !stop, inFlight.count < limit {
                    // Runs beside the upload pass: a pause or a waiting command ends it after the files in hand, like the import
                    // stage and the upload gate.
                    let commandWaits = await commandWaiting()
                    if interrupts.paused || commandWaits {
                        result.yielded = true
                        stop = true
                        break
                    }
                    let step = try await dispatchNext(excluding: inFlight.union(held).union(failed))
                    switch step {
                    case .none: stop = true
                    case .held(let id): held.insert(id)
                    case .skippedByRule: result.skippedByRule += 1
                    case .blocked(let block):
                        result.blockedBy = block
                        stop = true
                    case .started(let started):
                        inFlight.insert(started.id)
                        group.addTask { try await self.export(started) }
                    }
                }
                guard let outcome = try await group.next() else { break }
                inFlight.remove(outcome.id)
                switch outcome {
                case .exported: result.exported += 1
                case .failed(let id):
                    result.failed += 1
                    failed.insert(id)
                case .cancelledForDisk: result.cancelledForDisk += 1
                case .skippedByRule: result.skippedByRule += 1
                }
                if photosLost {
                    stop = true
                    result.photosUnavailable = true
                }
            }
        }
        return result
    }

    // MARK: Export

    private func export(_ started: Started) async throws -> Outcome {
        let key = started.asset.assetKey
        let type = started.resource.type
        let generation = started.resource.contentGen
        let url = staging.fileURL(assetKey: key, type: type, generation: generation)
        let permit = started.permit
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: url)
            let file = try await readResource(started, to: url)
            try env.reach(.afterExportBeforeCommit)
            let metadata = started.isPrimary
                ? env.metadataReader.metadata(of: url, uti: started.resource.uti, mediaType: started.asset.mediaType) : nil
            let env = env
            let kept: Bool = try await env.store.write { db in
                let done = try ResourceRepository.completeExport(
                    db, key: key, type: type, path: url.path, sizeBytes: file.size, md5: file.md5, sha256: file.sha256, now: env.clock.now)
                if done, let metadata, var asset = try AssetRepository.fetch(db, key: key) {
                    asset.cameraMake = metadata.make ?? asset.cameraMake
                    asset.cameraModel = metadata.model ?? asset.cameraModel
                    asset.lensModel = metadata.lensModel ?? asset.lensModel
                    let zone = try KeyValueRepository.archiveTimeZone(db) ?? .current
                    try AssetRepository.upsert(db, asset, timeZone: zone)
                }
                return done
            }
            await resourceGuard.finish(permit, actualBytes: file.size)
            if !kept { staging.remove(url) }
            try await skipOversized(key: key, type: type, size: file.size, destinations: started.needing)
            env.logJob(.info, "export", jobId: nil, "exported resource type=\(type.rawValue) bytes=\(file.size)")
            return .exported(started.id)
        } catch {
            await resourceGuard.finish(permit, actualBytes: nil)
            staging.remove(url)
            if error is EngineAbort || error is CancellationError { throw error }
            return try await handleFailure(error, started: started)
        }
    }

    private func handleFailure(_ error: any Error, started: Started) async throws -> Outcome {
        let key = started.asset.assetKey
        let type = started.resource.type
        let now = env.clock.now
        let permit = started.permit
        let source = error as? PhotosSourceError
        let folder = error as? SourceError
        if source == .cancelled || folder == .cancelled || permit.reason != nil {
            switch permit.reason {
            case .sizeRule:
                try await env.store.write { db in try EngineQueries.resetExportToNone(db, key: key, type: type) }
                try await skipOversized(key: key, type: type, size: permit.control.bytesReceived, destinations: started.needing, force: true)
                return .skippedByRule(started.id)
            case .disk:
                let received = permit.control.bytesReceived
                let tooLarge = DiskGuardPolicy.isTooLargeForDisk(
                    diskCancelCount: started.resource.diskCancelCount + 1, bytesReceivedAtCancel: received,
                    freeAtStart: permit.freeBytesAtStart, criticalWatermarkBytes: started.settings.criticalWatermarkBytes)
                try await env.store.write { db in
                    try ResourceRepository.cancelExportForDisk(
                        db, key: key, type: type, bytesReceived: received, tooLarge: tooLarge,
                        retryAt: now.addingTimeInterval(JobTransitions.deferredRetryInterval))
                    if tooLarge { try EngineQueries.apply(db, .tooLargeForDisk, key: key, type: type, states: [.pending], now: now) }
                }
                return .cancelledForDisk(started.id)
            case nil:
                // Cancelled without a reason of ours: the library went away underneath the export.
                // A cancelled task (shutdown, owner command) is not a lost library and needs no delay.
                let shuttingDown = Task.isCancelled
                if !shuttingDown, started.asset.sourceId == .photos { photosLost = true }
                let retryAt = shuttingDown ? nil : now.addingTimeInterval(Self.transientRetryDelay)
                try await env.store.write { db in try EngineQueries.resetExportToNone(db, key: key, type: type, retryAt: retryAt) }
                return .failed(started.id)
            }
        }
        let classification: ErrorClass
        var retryDelay = Self.transientRetryDelay
        if let source { classification = ErrorClassifier.classify(source) } else if let folder {
            (classification, retryDelay) = try await classifyFolderFailure(folder, asset: started.asset)
        } else { classification = .itemLevel }
        let message = source.map { "photos: \($0)" } ?? folder.map { "source: \($0)" } ?? "export failed"
        switch classification {
        case .permanent(let reason):
            try await env.store.write { db in
                try EngineQueries.resetExportToNone(db, key: key, type: type)
                try EngineQueries.apply(db, .permanentFailure(reason, message: message), key: key, type: type, states: [.pending], now: now)
            }
        case .destinationLevel, .transient, .verify:
            if case .destinationLevel = classification {
                if folder != nil { try await holdSource(of: started.asset, at: now, reason: folder == .accessRevoked ? SourceStatusReason.signInRequired : SourceStatusReason.unavailable) } else { photosLost = true }
            }
            let delay = retryDelay
            // A folder that is away is waiting, not failing: no error is recorded against the file.
            let held = folder != nil && (folder == .busy || { if case .destinationLevel = classification { true } else { false } }())
            try await env.store.write { db in
                try EngineQueries.resetExportToNone(db, key: key, type: type, retryAt: now.addingTimeInterval(delay))
                // A source that is away is waiting, not failing: an error from before must not keep counting.
                if held { try ResourceRepository.clearExportError(db, key: key, type: type) } else {
                    try ResourceRepository.noteExportError(db, key: key, type: type, message: message)
                }
            }
        case .itemLevel:
            let delay = env.tuning.backoffDelay(started.resource.exportAttempts)
            try await env.store.write { db in
                let attempts = try ResourceRepository.failExport(
                    db, key: key, type: type, message: message, retryAt: now.addingTimeInterval(delay), now: now)
                if let attempts, attempts > JobTransitions.maxAttempts {
                    try EngineQueries.apply(db, .exportGaveUp, key: key, type: type, states: [.pending], now: now)
                }
            }
        }
        env.logJob(.notice, "export", jobId: nil, "export failed class=\(classification)")
        return .failed(started.id)
    }
}
