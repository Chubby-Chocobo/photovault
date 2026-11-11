import Foundation
import PhotoVaultCore
import PhotoVaultStore

struct UploadPassResult: Sendable, Equatable {
    var uploaded = 0
    var perDestination: [DestinationID: Int] = [:]
}

enum UploadOutcome: Sendable, Equatable {
    case done(bytes: Int64)
    /// Back to `pending` with a backoff (item error) or waiting for its staging again.
    case requeued
    /// Skipped for good (permanent error or a rule).
    case skipped
    /// A destination-level error ended the destination's pass.
    case stopDestination
    /// Not handled in this phase (sidecars) or not placed yet.
    case unsupported
}

/// Asked before every job starts; the coordinator re-checks pause, network, power and waiting
/// owner commands here, so a long pass reacts within one job.
/// A staged file, by asset and resource type.
struct StagedFile: Hashable, Sendable {
    var assetKey: AssetKey
    var type: ResourceType
}

struct UploadGate: Sendable {
    var mayStart: @Sendable () async -> Bool
    static let open = UploadGate(mayStart: { true })
}

/// Step 6 of the cycle: fan-out of ready jobs to every accepting destination, at most
/// `maxConcurrentUploadsPerDestination` at a time per destination (NFR-03). Destination state
/// that outlives a pass (consecutive failures, backoff, folder creation) is kept here.
actor UploadRunner {
    let env: EngineEnvironment
    let staging: StagingManager
    private var ensurers: [DestinationID: FolderEnsurer] = [:]
    private var consecutiveFailures: [DestinationID: Int] = [:]
    private var backoffUntil: [DestinationID: Date] = [:]
    private var activePasses: [DestinationID: Task<Int, any Error>] = [:]

    init(env: EngineEnvironment, staging: StagingManager) {
        self.env = env
        self.staging = staging
    }

    // MARK: Destination state

    func consecutive(_ id: DestinationID) -> Int { consecutiveFailures[id, default: 0] }

    func noteSuccess(_ id: DestinationID) {
        consecutiveFailures[id] = nil
        backoffUntil[id] = nil
    }

    func noteFailure(_ id: DestinationID) { consecutiveFailures[id, default: 0] += 1 }

    /// True while a rate limit or server error keeps the destination quiet. Uploads and moves share it:
    /// both spend the same quota.
    func isBackedOff(_ id: DestinationID) -> Bool { (backoffUntil[id] ?? .distantPast) > env.clock.now }

    func backOff(_ id: DestinationID) {
        let delay = env.tuning.backoffDelay(max(consecutiveFailures[id, default: 1] - 1, 0))
        backoffUntil[id] = env.clock.now.addingTimeInterval(delay)
    }

    func ensurer(for record: DestinationRecord, destination: any Destination) -> FolderEnsurer {
        if let existing = ensurers[record.id] { return existing }
        let created = FolderEnsurer(env: env, destination: destination, record: record)
        ensurers[record.id] = created
        return created
    }

    /// Forgets cached folder state of a destination (reset or root change).
    func forget(_ id: DestinationID) {
        ensurers[id] = nil
        consecutiveFailures[id] = nil
        backoffUntil[id] = nil
    }

    // MARK: Pass

    /// Uploads for every destination concurrently. `maxJobsPerDestination` bounds a step-by-step run. With `stagedAtStart`,
    /// only files staged when the pass began are sent (sidecars always are): a pass that runs beside the exports leaves
    /// what they stage meanwhile to the next round, so that round has something to send while the next batch is read.
    func runPass(maxJobsPerDestination: Int? = nil, gate: UploadGate = .open, stagedAtStart: Set<StagedFile>? = nil) async throws -> UploadPassResult {
        let ids = await env.destinations.ids
        var result = UploadPassResult()
        try await withThrowingTaskGroup(of: (DestinationID, Int).self) { group in
            for id in ids {
                group.addTask { (id, try await self.runCancellable(id, maxJobs: maxJobsPerDestination, gate: gate, staged: stagedAtStart)) }
            }
            for try await (id, count) in group {
                result.uploaded += count
                if count > 0 { result.perDestination[id] = count }
            }
        }
        return result
    }

    /// Stops the transfers of one destination (root change, removal); the others keep running.
    /// Their jobs stay `uploading` and are resolved by recovery.
    func cancelUploads(of id: DestinationID) { activePasses[id]?.cancel() }

    private func runCancellable(_ id: DestinationID, maxJobs: Int?, gate: UploadGate, staged: Set<StagedFile>?) async throws -> Int {
        let task = Task { try await self.runDestination(id, maxJobs: maxJobs, gate: gate, staged: staged) }
        activePasses[id] = task
        defer { if activePasses[id] == task { activePasses[id] = nil } }
        do {
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch is CancellationError {
            if Task.isCancelled { throw CancellationError() }
            return 0
        }
    }

    private func runDestination(_ id: DestinationID, maxJobs: Int?, gate: UploadGate, staged: Set<StagedFile>?) async throws -> Int {
        guard let record = try await env.store.read({ db in try DestinationRepository.fetch(db, id: id) }), record.acceptsUploads,
              let destination = await env.destinations.destination(for: id) else { return 0 }
        if isBackedOff(id) { return 0 }
        let ensurer = ensurer(for: record, destination: destination)
        let limit = max(1, env.tuning.maxConcurrentUploadsPerDestination)
        var attempted = Set<Int64>()
        // Ready jobs left for the next round (their file was staged after the pass began).
        var later = Set<Int64>()
        var buffer: [JobRepository.ReadyJob] = []
        var inFlight = Set<Int64>()
        var uploaded = 0
        var dispatched = 0
        var stop = false
        try await withThrowingTaskGroup(of: (Int64, UploadOutcome).self) { group in
            while true {
                try Task.checkCancellation()
                while !stop, inFlight.count < limit, dispatched < (maxJobs ?? .max) {
                    // Pause, network, power, the destination's status and waiting owner commands can
                    // change during a pass that lasts hours: ask again before every job.
                    guard await gate.mayStart(),
                          let current = try await env.store.read({ db in try DestinationRepository.fetch(db, id: id) }),
                          current.acceptsUploads else {
                        stop = true
                        break
                    }
                    if buffer.isEmpty {
                        // One ranking query per window, not per job.
                        let now = env.clock.now
                        let window = 200 + attempted.count + later.count
                        let ready = try await env.store.read { db in
                            try JobRepository.readyToUpload(db, destinationId: id, now: now, limit: window)
                        }.filter { item in item.job.id.map { !attempted.contains($0) && !later.contains($0) } ?? false }
                        buffer = []
                        for item in ready {
                            if let staged, let resource = item.resource, !staged.contains(StagedFile(assetKey: resource.assetKey, type: resource.type)) {
                                if let jobId = item.job.id { later.insert(jobId) }
                            } else {
                                buffer.append(item)
                            }
                        }
                    }
                    guard !buffer.isEmpty else { break }
                    let next = buffer.removeFirst()
                    guard let jobId = next.job.id else { continue }
                    attempted.insert(jobId)
                    inFlight.insert(jobId)
                    dispatched += 1
                    let attempt = UploadAttempt(
                        env: env, staging: staging, runner: self, destination: destination, record: current, ensurer: ensurer, ready: next)
                    group.addTask { (jobId, try await attempt.run()) }
                }
                guard let (jobId, outcome) = try await group.next() else { break }
                inFlight.remove(jobId)
                switch outcome {
                case .done: uploaded += 1
                case .stopDestination: stop = true
                case .requeued, .skipped, .unsupported: break
                }
            }
        }
        return uploaded
    }
}
