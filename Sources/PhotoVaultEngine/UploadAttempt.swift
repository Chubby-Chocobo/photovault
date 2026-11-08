import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// One attempt to deliver one job (spec 8.3, 8.14). Order of side effects, each persisted before
/// the next: folders (reserved id persisted, then created) → file id reserved and persisted →
/// `startUpload` persisted → upload (session persisted before the first byte) → hash verified →
/// `uploadSucceeded` plus layout comparison in one transaction. After a crash at any point the
/// reserved ids make a repeat idempotent: an `alreadyExists` answer is verified with a probe.
struct UploadAttempt: Sendable {
    let env: EngineEnvironment
    let staging: StagingManager
    let runner: UploadRunner
    let destination: any Destination
    let record: DestinationRecord
    let ensurer: FolderEnsurer
    let ready: JobRepository.ReadyJob

    var identity: JobIdentity { ready.job.identity }
    var hashKind: ContentHashKind { destination.capabilities.verifiedHash }

    init(env: EngineEnvironment, staging: StagingManager, runner: UploadRunner, destination: any Destination,
         record: DestinationRecord, ensurer: FolderEnsurer, ready: JobRepository.ReadyJob) {
        self.env = env
        self.staging = staging
        self.runner = runner
        self.destination = destination
        self.record = record
        self.ensurer = ensurer
        self.ready = ready
    }

    func run() async throws -> UploadOutcome {
        let isSidecar = identity.resType.isSidecar
        guard isSidecar || ready.resource != nil else { return .unsupported }
        // The ready list may be a little stale: only a job that is still pending may start.
        let id = identity
        let current = try await env.store.read { db in try JobRepository.fetch(db, identity: id) }
        guard let current, current.state == .pending, (current.nextAttemptAt ?? .distantPast) <= env.clock.now else { return .unsupported }
        let outcome: UploadOutcome
        do {
            if isSidecar {
                outcome = try await performSidecar()
            } else if let resource = ready.resource {
                outcome = try await perform(resource)
            } else {
                return .unsupported
            }
        } catch {
            if error is EngineAbort || error is CancellationError { throw error }
            return try await handleFailure(error)
        }
        if case .done = outcome { try await staging.releaseUnneeded(asset: identity.assetKey) }
        return outcome
    }

    // MARK: Delivery

    private func perform(_ resource: ResourceRecord) async throws -> UploadOutcome {
        let snapshot = await env.settingsSnapshot()
        let job = ready.job
        let layout = env.layout
        let builder = env.nameBuilder(snapshot.timeZone)
        guard let plan = try await env.store.read({ db in
            try LayoutResolver.plan(db, job: job, resource: resource, layout: layout, nameBuilder: builder)
        }) else { return .unsupported }
        guard let path = resource.stagingPath, FileManager.default.fileExists(atPath: path),
              let md5 = resource.md5, let sha256 = resource.sha256, let size = resource.sizeBytes else {
            // The staged file is gone: export it again.
            try await env.store.write { db in _ = try ResourceRepository.releaseStaging(db, key: resource.assetKey, type: resource.type) }
            return .requeued
        }
        if let cap = record.rules.skipLargerThanBytes, size > cap {
            try await apply(.permanentFailure(.tooLargeForRule, message: "larger than destination limit"))
            return .skipped
        }
        let settings = snapshot.settings
        let description: String? = destination.capabilities.supportsDescription
            ? try await env.store.read { db in try OrganizationLookups.descriptionText(db, asset: plan.asset, settings: settings) } : nil
        await staging.lease(path)
        let outcome: UploadOutcome
        do {
            outcome = try await transfer(
                generation: resource.stagingGen, plan: plan, description: description,
                content: StagedContent(file: URL(fileURLWithPath: path), size: size, md5: md5, sha256: sha256))
        } catch {
            await staging.unlease(path)
            throw error
        }
        await staging.unlease(path)
        return outcome
    }

    func transfer(generation: Int, plan: UploadPlan, description: String?, content staged: StagedContent) async throws -> UploadOutcome {
        let parent = try await ensurer.ensure(plan.chain)
        var job = ready.job
        if destination.capabilities.reservesIds, job.remoteId == nil {
            guard let reserved = try await destination.reserveIds(count: 1, kind: .files).first else {
                throw DestinationError.itemRejected(reason: "no file id reserved")
            }
            try env.reach(.afterFileIdReserved)
            job = try await apply(.reserved(remoteId: reserved))
            try env.reach(.afterFileIdPersisted)
        }
        job = try await apply(.startUpload(generation: generation))
        try env.reach(.afterStartUpload)
        env.logJob(.info, "upload", jobId: job.id, "start type=\(job.resType.rawValue) bytes=\(staged.size)")
        let content = try await env.transform.apply(to: staged)
        let request = UploadRequest(
            job: identity, jobId: job.id, kind: job.kind, reservedRemoteId: job.remoteId, parent: parent,
            fileName: plan.fileName, content: content, appProperties: plan.properties, description: description,
            expectedPriorHash: job.uploadedHash)
        guard let result = try await deliver(request, job: job) else { return .skipped }
        try env.reach(.afterUploadBeforeCommit)
        let now = env.clock.now
        let layout = env.layout
        let id = identity
        // A refresh replaces the file where it is; only a first upload lands in the folder just ensured.
        let replacedInPlace = job.doneGen > 0 && job.remoteId != nil
        let parentLogical = replacedInPlace ? (job.remoteLogicalParent ?? plan.parentLogical) : plan.parentLogical
        _ = try await env.store.write { db in
            try UploadCompletion.commit(
                db, identity: id, remoteId: result.remoteId, finalName: result.finalName, uploadedParent: parentLogical,
                verifiedHash: result.verifiedHash, layout: layout, description: description, now: now)
        }
        await runner.noteSuccess(record.id)
        env.logJob(.info, "upload", jobId: job.id, "done")
        try env.reach(.afterCommitBeforeRelease)
        return .done(bytes: content.size)
    }

    /// Sends the content and verifies its hash. Returns nil when the job ended up skipped.
    private func deliver(_ request: UploadRequest, job startJob: UploadJob) async throws -> UploadResult? {
        var job = startJob
        var transientAttempts = 0
        var verifyAttempts = 0
        var probeFirst = false
        var skipResume = false
        var forceReplace = false
        while true {
            do {
                var result = try await attempt(request, job: job, probeFirst: probeFirst, skipResume: skipResume, forceReplace: forceReplace)
                if job.remoteId == nil {
                    job = try await apply(.reserved(remoteId: result.remoteId))
                }
                let expected = request.content.hash(hashKind)
                while result.verifiedHash != expected {
                    job = try await apply(.checksumMismatch)
                    if job.state == .skipped { return nil }
                    env.logJob(.notice, "upload", jobId: job.id, "checksum mismatch, replacing content")
                    var repair = request
                    repair.expectedPriorHash = result.verifiedHash
                    result = try await destination.replaceContent(remoteId: result.remoteId, repair)
                }
                return result
            } catch let error as DestinationError {
                if case .checksumMismatch = error {
                    job = try await apply(.checksumMismatch)
                    if job.state == .skipped { return nil }
                    forceReplace = job.remoteId != nil
                    continue
                }
                switch ErrorClassifier.classify(error, consecutiveFailures: await runner.consecutive(record.id)) {
                case .transient:
                    transientAttempts += 1
                    guard transientAttempts <= env.tuning.transientRetries else { throw error }
                    try await env.tuning.sleep(Backoff().delay(forAttempt: transientAttempts - 1))
                    probeFirst = true
                case .verify:
                    verifyAttempts += 1
                    guard verifyAttempts <= 3 else { throw error }
                    switch error {
                    case .alreadyExists: probeFirst = true
                    case .sessionExpired: skipResume = true
                    default: throw error
                    }
                default:
                    throw error
                }
            }
        }
    }

    private func attempt(_ request: UploadRequest, job: UploadJob, probeFirst: Bool, skipResume: Bool, forceReplace: Bool) async throws -> UploadResult {
        let persist: @Sendable (SessionCheckpoint) async throws -> Void = { checkpoint in
            try await self.apply(.sessionStarted(checkpoint))
            try self.env.reach(.afterSessionPersisted)
        }
        if probeFirst, let remoteId = job.remoteId, let item = try await destination.probe(remoteId: remoteId), !item.trashed {
            return try await settle(item, request)
        }
        if forceReplace, let remoteId = job.remoteId {
            return try await destination.replaceContent(remoteId: remoteId, request)
        }
        if !skipResume, let ref = job.sessionRef, let md5 = job.sessionMd5, job.remoteId != nil {
            do {
                return try await destination.resumeUpload(
                    request, session: SessionCheckpoint(sessionRef: ref, md5: md5, totalBytes: request.content.size), onSession: persist)
            } catch DestinationError.sessionExpired {
                // The session is gone; a fresh one is opened for the same reserved id below.
            }
        }
        if let remoteId = job.remoteId, job.doneGen > 0, job.uploadedHash != nil {
            return try await destination.replaceContent(remoteId: remoteId, request)
        }
        return try await destination.upload(request, onSession: persist)
    }

    /// The file already exists at the destination: accept it when the content matches, otherwise
    /// replace it in place (same id, never a second file).
    private func settle(_ item: RemoteItem, _ request: UploadRequest) async throws -> UploadResult {
        let remoteHash = hashKind == .md5 ? item.md5 : item.sha256
        if let remoteHash, remoteHash == request.content.hash(hashKind) {
            return UploadResult(
                remoteId: item.remoteId, finalName: item.name, verifiedHash: remoteHash, parentIds: item.parentIds,
                trashed: false, size: item.size ?? request.content.size)
        }
        return try await destination.replaceContent(remoteId: item.remoteId, request)
    }

    // MARK: Job transitions

    @discardableResult
    func apply(_ event: JobEvent) async throws -> UploadJob {
        let id = identity
        let now = env.clock.now
        return try await env.store.write { db in try JobRepository.apply(db, event, to: id, now: now) }
    }

    /// Applies an event, ignoring a transition that is no longer valid (the job moved on).
    private func applyIfValid(_ event: JobEvent) async throws {
        do {
            try await apply(event)
        } catch is JobTransitionError {
            env.logJob(.notice, "upload", jobId: ready.job.id, "transition no longer valid")
        }
    }

    // MARK: Errors (spec 8.14)

    private func handleFailure(_ error: any Error) async throws -> UploadOutcome {
        guard let failure = error as? DestinationError else {
            env.logJob(.error, "upload", jobId: ready.job.id, "unexpected error type=\(type(of: error))")
            return try await itemFailure("unexpected error")
        }
        let consecutive = await runner.consecutive(record.id)
        var classification = ErrorClassifier.classify(failure, consecutiveFailures: consecutive)
        if case .transient = classification {
            classification = ErrorClassifier.classify(failure, consecutiveFailures: consecutive + env.tuning.transientRetries + 1)
        }
        env.logJob(.notice, "upload", jobId: ready.job.id, "failed error=\(failure) class=\(classification)")
        switch classification {
        case .destinationLevel(let status):
            await runner.noteFailure(record.id)
            if let status {
                let id = record.id
                let now = env.clock.now
                try await env.store.write { db in try DestinationRepository.setStatus(db, id: id, status: status, now: now) }
                await ActivityLog(env: env).statusChanged(id, to: status)
            } else {
                await runner.backOff(record.id)
            }
            try await applyIfValid(.destinationFailure(message: failure.description))
            return .stopDestination
        case .permanent(let reason):
            try await applyIfValid(.permanentFailure(reason, message: failure.description))
            return .skipped
        case .verify:
            if case .folderMissing(let path) = failure {
                try await ensurer.invalidate(logicalPath: path)
                try await applyIfValid(.destinationFailure(message: failure.description))
                return .requeued
            }
            return try await itemFailure(failure.description)
        case .itemLevel, .transient:
            return try await itemFailure(failure.description)
        }
    }

    private func itemFailure(_ message: String) async throws -> UploadOutcome {
        let current = try await env.store.read { db in try JobRepository.fetch(db, identity: identity) }
        let delay = Backoff().delay(forAttempt: current?.attempts ?? 0)
        try await applyIfValid(.itemFailure(message: message, retryAt: env.clock.now.addingTimeInterval(delay)))
        return .requeued
    }
}
