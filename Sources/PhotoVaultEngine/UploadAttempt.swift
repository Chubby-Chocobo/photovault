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
            if let stored = error as? StoreError, case .notFound = stored {
                // The job was removed meanwhile (destination reset): nothing to record, nothing to fail.
                env.logJob(.notice, "upload", jobId: ready.job.id, "job no longer exists")
                return .unsupported
            }
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
        guard let path = resource.stagingPath, resource.md5 != nil, resource.sha256 != nil, resource.sizeBytes != nil else {
            // No staged file recorded: export it again.
            try await env.store.write { db in _ = try ResourceRepository.releaseStaging(db, key: resource.assetKey, type: resource.type) }
            return .requeued
        }
        // The lease comes before every look at the file: a release in progress refuses it and the
        // job waits for the export again, a release that comes later sees the lease and stops.
        guard await staging.lease(path) else { return .requeued }
        let outcome: UploadOutcome
        do {
            outcome = try await performLeased(resource, path: path, plan: plan, snapshot: snapshot)
        } catch {
            await staging.unlease(path)
            throw error
        }
        await staging.unlease(path)
        return outcome
    }

    private func performLeased(_ resource: ResourceRecord, path: String, plan: UploadPlan, snapshot: SettingsSnapshot) async throws -> UploadOutcome {
        guard FileManager.default.fileExists(atPath: path),
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
        return try await transfer(
            generation: resource.stagingGen, plan: plan, description: description,
            content: StagedContent(file: URL(fileURLWithPath: path), size: size, md5: md5, sha256: sha256))
    }

    /// Retries `.transient` destination errors inside the pass, as the upload itself does: a dropped
    /// connection while creating a folder or reserving an id costs the job no attempt.
    private func retryingTransient<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        var tries = 0
        while true {
            do {
                return try await body()
            } catch let error as DestinationError {
                guard case .transient = error, tries < env.tuning.transientRetries else { throw error }
                try await env.tuning.sleep(Backoff().delay(forAttempt: tries))
                tries += 1
            }
        }
    }

    func transfer(generation: Int, plan: UploadPlan, description: String?, content staged: StagedContent) async throws -> UploadOutcome {
        let ensurer = ensurer
        let parent = try await retryingTransient { try await ensurer.ensure(plan.chain) }
        var job = ready.job
        if destination.capabilities.reservesIds, job.remoteId == nil {
            let destination = destination
            guard let reserved = try await retryingTransient({ try await destination.reserveIds(count: 1, kind: .files) }).first else {
                throw DestinationError.itemRejected(reason: "no file id reserved")
            }
            try env.reach(.afterFileIdReserved)
            job = try await apply(.reserved(remoteId: reserved))
            try env.reach(.afterFileIdPersisted)
        }
        let content = try await env.transform.apply(to: staged)
        job = try await startUpload(generation: generation, job: job, parent: parent, fileName: plan.fileName, content: content)
        try env.reach(.afterStartUpload)
        env.logJob(.info, "upload", jobId: job.id, "start type=\(job.resType.rawValue) bytes=\(staged.size)")
        let request = UploadRequest(
            job: identity, jobId: job.id, kind: job.kind, reservedRemoteId: job.remoteId, parent: parent,
            fileName: plan.fileName, content: content, appProperties: plan.properties, description: description,
            expectedPriorHash: job.uploadedHash)
        let transfer = ready.resource.map {
            env.transfers.begin(
                kind: record.kind == .googleDrive ? .upload : .copy, fileName: $0.originalFilename,
                destinationName: record.displayName, accountEmail: record.kind == .googleDrive ? record.accountEmail : nil,
                sourceId: plan.asset.sourceId, bytesTotal: content.size)
        }
        defer { transfer?.end() }
        var tracked = request
        tracked.progress = transfer?.sink
        guard let result = try await deliver(tracked, job: job) else { return .skipped }
        // FR-47: every write answer is checked; a file that landed in a trashed folder is not done.
        if result.trashed { throw DestinationError.folderTrashed(logicalPath: plan.parentLogical) }
        try env.reach(.afterUploadBeforeCommit)
        let now = env.clock.now
        let layout = env.layout
        let id = identity
        // A refresh replaces the file where it is; only a first upload lands in the folder just ensured.
        let replacedInPlace = job.doneGen > 0 && job.remoteId != nil
        // A resumed session keeps the parent it was opened with, so the folder the file landed in
        // is taken from the answer; the commit queues the move to where the layout wants it now.
        let parentLogical = replacedInPlace
            ? (job.remoteLogicalParent ?? plan.parentLogical)
            : try await landedParent(result.parentIds, planned: plan.parentLogical)
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

    /// The logical folder whose remote id is one of `parentIds`; the planned one when none is known.
    private func landedParent(_ parentIds: [String], planned: String) async throws -> String {
        guard !parentIds.isEmpty else { return planned }
        let destinationId = record.id
        let folders = try await env.store.read { db in try RemoteFolderRepository.fetchAll(db, destinationId: destinationId) }
        if let match = folders.first(where: { $0.logicalPath == planned }), let id = match.remoteId, parentIds.contains(id) { return planned }
        return folders.first { $0.remoteId.map(parentIds.contains) ?? false }?.logicalPath ?? planned
    }

    /// `pending → uploading`. A destination that does not reserve ids is addressed by path: the path
    /// about to be written and the hash of the content are saved in the same transaction, so that
    /// recovery after a crash probes exactly that file (spec 8.3, FR-44).
    private func startUpload(generation: Int, job: UploadJob, parent: RemoteFolderRef, fileName: String, content: StagedContent) async throws -> UploadJob {
        guard !destination.capabilities.reservesIds else { return try await apply(.startUpload(generation: generation)) }
        let path = (job.doneGen > 0 ? job.remoteId : nil) ?? (parent.remoteId.isEmpty ? fileName : parent.remoteId + "/" + fileName)
        let id = identity
        let now = env.clock.now
        let sha256 = content.sha256
        let destinationId = record.id
        return try await env.store.write { db in
            let started = try JobRepository.apply(db, .startUpload(generation: generation), to: id, now: now)
            if let jobId = started.id {
                try UploadIntentRepository.save(db, UploadIntent(
                    jobId: jobId, destinationId: destinationId, remotePath: path, contentSha256: sha256, createdAt: now))
            }
            return started
        }
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
            // A session belongs to the content it was opened for: after an edit or a re-export it
            // is dropped and a new one is opened for the same reserved id.
            if let sessionMd5 = job.sessionMd5, sessionMd5 != request.content.md5 {
                env.logJob(.notice, "upload", jobId: job.id, "session was opened for other content, dropped")
                job = try await apply(.sessionDropped)
            }
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
            return try await replaceUploaded(remoteId, request, job: job)
        }
        if !skipResume, let ref = job.sessionRef, let md5 = job.sessionMd5, job.remoteId != nil {
            do {
                return try await destination.resumeUpload(
                    request, session: SessionCheckpoint(sessionRef: ref, md5: md5, totalBytes: request.content.size), onSession: persist)
            } catch DestinationError.sessionExpired {
                // The session is gone; a fresh one is opened for the same reserved id below.
                try await applyIfValid(.sessionDropped)
            } catch let error as DestinationError {
                // The destination rejects this session for this content: never offer it again.
                if case .itemLevel = ErrorClassifier.classify(error, consecutiveFailures: 0) { try await applyIfValid(.sessionDropped) }
                throw error
            }
        }
        if let remoteId = job.remoteId, job.doneGen > 0, job.uploadedHash != nil {
            return try await replaceUploaded(remoteId, request, job: job)
        }
        return try await destination.upload(request, onSession: persist)
    }

    /// Replaces a file uploaded before. When it is gone from the destination, retrying cannot help.
    private func replaceUploaded(_ remoteId: String, _ request: UploadRequest, job: UploadJob) async throws -> UploadResult {
        do {
            return try await destination.replaceContent(remoteId: remoteId, request)
        } catch DestinationError.notFound where job.doneGen > 0 {
            throw UploadedFileGone()
        }
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
}
