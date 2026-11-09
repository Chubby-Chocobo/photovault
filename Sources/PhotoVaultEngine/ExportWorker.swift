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
}

/// Step 4 of the cycle (FR-30..34, FR-23, NFR-09). Each resource is exported once for every
/// available destination that needs it. Candidates run incremental > refresh > reupload >
/// backfill, newest first, the primary resource of an asset before its others; at most
/// `maxConcurrentExports` run at once. Only placed assets are exported, so nothing is staged
/// before the placement exists.
actor ExportWorker {
    let env: EngineEnvironment
    private let resourceGuard: ResourceGuard
    private let staging: StagingManager
    /// Candidates fetched once and consumed in order; refetched when exhausted, so a pass over a
    /// large backlog does not repeat the ranking query for every export.
    private var queue: [Candidate] = []
    /// Set by a failure that says Photos itself is unusable; ends the running pass.
    private var photosLost = false
    /// A resource that failed without a reason of its own waits this long before it is picked again.
    static let transientRetryDelay: TimeInterval = 60

    init(env: EngineEnvironment, resourceGuard: ResourceGuard, staging: StagingManager) {
        self.env = env
        self.resourceGuard = resourceGuard
        self.staging = staging
    }

    private struct Candidate: Sendable {
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

    // MARK: Dispatch

    private enum Step {
        case none, held(String), skippedByRule, blocked(DiskGuardBlock), started(Started)
    }

    private func candidates(backfillAllowed: Bool) async throws -> [Candidate] {
        let now = env.clock.now
        return try await env.store.read { db in
            let rows = try EngineQueries.exportCandidates(db, now: now, backfillAllowed: backfillAllowed, limit: 200)
            var primaries: [AssetKey: ResourceType?] = [:]
            var list: [Candidate] = []
            for row in rows {
                if primaries[row.key] == nil {
                    let descriptors = try ResourceRepository.fetchAll(db, key: row.key).map(\.descriptor)
                    primaries[row.key] = .some(ResourcePlanner.primary(of: descriptors)?.type)
                }
                list.append(Candidate(row: row, isPrimary: primaries[row.key] == .some(row.type)))
            }
            return list.sorted {
                ($0.row.priority, $1.row.creationDate ?? .distantPast, $0.row.key, $0.isPrimary ? 0 : 1)
                    < ($1.row.priority, $0.row.creationDate ?? .distantPast, $1.row.key, $1.isPrimary ? 0 : 1)
            }
        }
    }

    private func dispatchNext(excluding: Set<String>) async throws -> Step {
        if queue.isEmpty {
            let scanComplete = try await env.store.read { db in try KeyValueRepository.scanState(db) } == .complete
            queue = try await candidates(backfillAllowed: scanComplete).filter { !excluding.contains($0.id) }
        }
        let settings = await env.settingsSnapshot().settings
        while !queue.isEmpty {
            let candidate = queue.removeFirst()
            if excluding.contains(candidate.id) { continue }
            let key = candidate.row.key
            let type = candidate.row.type
            let loaded: (AssetRecord, ResourceRecord, [DestinationRecord])? = try await env.store.read { db in
                guard let asset = try AssetRepository.fetch(db, key: key), let resource = try ResourceRepository.fetch(db, key: key, type: type)
                else { return nil }
                return (asset, resource, try EngineQueries.destinationsNeeding(db, key: key, type: type))
            }
            guard let (asset, resource, needing) = loaded, !needing.isEmpty else { return .held(candidate.id) }
            if let size = resource.sizeBytes, needing.allSatisfy({ ($0.rules.skipLargerThanBytes ?? .max) < size }) {
                try await skipOversized(key: key, type: type, size: size, destinations: needing)
                return .skippedByRule
            }
            let rateLimited = candidate.row.exportCount >= 1 || candidate.row.origins.allSatisfy(\.isRateLimited)
            let estimate = resource.sizeBytes ?? (type == .video || type == .fullSizeVideo ? 128 << 20 : 8 << 20)
            switch await resourceGuard.admit(rateLimited: rateLimited, estimatedBytes: estimate, sizeLimit: Self.sizeCutoff(needing)) {
            case .denied(.stopAll(let block)): return .blocked(block)
            case .denied(.rateLimited): return .held(candidate.id)
            case .granted(let permit):
                let began = try await env.store.write { db in
                    try ResourceRepository.beginExport(db, key: key, type: type, generation: resource.contentGen)
                }
                guard began else {
                    await resourceGuard.finish(permit, actualBytes: nil)
                    return .held(candidate.id)
                }
                return .started(Started(
                    id: candidate.id, permit: permit, asset: asset, resource: resource, needing: needing,
                    isPrimary: candidate.isPrimary, settings: settings))
            }
        }
        return .none
    }

    /// FR-33: the stream is cancelled early only when every destination that needs the file has a cap.
    private static func sizeCutoff(_ destinations: [DestinationRecord]) -> Int64? {
        let limits = destinations.map(\.rules.skipLargerThanBytes)
        guard !limits.isEmpty, limits.allSatisfy({ $0 != nil }) else { return nil }
        return limits.compactMap { $0 }.max()
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
            let delay = Backoff().delay(forAttempt: started.resource.exportAttempts)
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
