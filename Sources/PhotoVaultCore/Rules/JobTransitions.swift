import Foundation

/// Events that move an upload job through the spec 8.3 state machine.
public enum JobEvent: Hashable, Sendable {
    /// The engine reserved and persisted a remote ID before any create.
    case reserved(remoteId: String)
    /// `pending → uploading`; `generation` is the staged content generation being sent.
    case startUpload(generation: Int)
    /// A resumable session was opened; persisted before the first byte.
    case sessionStarted(SessionCheckpoint)
    /// The resumable session no longer fits the content (another generation, or the destination
    /// forgot it): the next attempt opens a new one for the same reserved id.
    case sessionDropped
    /// Upload finished and the checksum matched.
    case uploadSucceeded(remoteId: String, finalName: String, parent: String, verifiedHash: String)
    /// Checksum differed; the engine re-sends media to the same ID.
    case checksumMismatch
    /// Staging was released or lost while uploading.
    case stagingLost
    /// Item-level failure (8.14); `retryAt` is the backoff deadline.
    case itemFailure(message: String, retryAt: Date)
    /// The resource failed to export more than `maxAttempts` times (FR-23).
    case exportGaveUp
    /// The resource is known not to fit on disk (FR-31); excluded from the 30-day expiry.
    case tooLargeForDisk
    /// Destination-level failure: back to pending, attempts untouched.
    case destinationFailure(message: String)
    /// 24 h elapsed since deferral, or the owner asked to retry.
    case retryDeferred
    /// Deferred for more than 30 days.
    case deferralExpired
    /// The owner retried a skipped job.
    case retrySkipped
    /// Permanent failure: skip now.
    case permanentFailure(JobStateReason, message: String)
    /// New content generation to deliver (edit, sidecar change).
    case contentChanged(targetGen: Int)
    /// Integrity check found the file missing at the destination.
    case missingAtDestination
    /// The owner confirmed re-uploading a missing file.
    case reuploadConfirmed
    /// A file marked missing is at the destination again (restored from the trash).
    case foundAgain
    /// Scope or rules narrowed.
    case cancel
    /// Scope or rules widened again.
    case reinstate(origin: JobOrigin)
}

public enum JobTransitionError: Error, Hashable, Sendable {
    case invalid(from: JobState, event: String)
}

/// The single implementation of spec 8.3. Every module changes jobs only through this type.
public enum JobTransitions {
    public static let maxAttempts = 8
    public static let maxChecksumMismatches = 3
    public static let deferredRetryInterval: TimeInterval = 24 * 3600
    public static let deferralLimit: TimeInterval = 30 * 24 * 3600

    public static func apply(_ event: JobEvent, to job: UploadJob, now: Date) throws -> UploadJob {
        var j = job
        j.updatedAt = now
        switch (job.state, event) {
        case (_, .reserved(let id)):
            guard j.remoteId == nil else { return job }
            j.remoteId = id

        case (.pending, .startUpload(let gen)):
            j.state = .uploading
            j.uploadingGen = gen
            j.lastError = nil

        case (.uploading, .sessionStarted(let checkpoint)):
            j.sessionRef = checkpoint.sessionRef
            j.sessionMd5 = checkpoint.md5

        case (.pending, .sessionDropped), (.uploading, .sessionDropped):
            j.sessionRef = nil
            j.sessionMd5 = nil

        case (.uploading, let .uploadSucceeded(remoteId, finalName, parent, hash)):
            j.remoteId = remoteId
            j.remoteName = finalName
            j.remoteLogicalParent = parent
            j.uploadedHash = hash
            j.doneGen = j.uploadingGen ?? j.targetGen
            j.uploadingGen = nil
            j.sessionRef = nil
            j.sessionMd5 = nil
            j.attempts = 0
            j.mismatchCount = 0
            j.nextAttemptAt = nil
            j.deferredSince = nil
            j.stateReason = nil
            j.lastError = nil
            if j.doneGen < j.targetGen {
                j.state = .pending
                j.origin = .refresh
            } else {
                j.state = .done
            }

        case (.uploading, .checksumMismatch):
            j.mismatchCount += 1
            if j.mismatchCount > maxChecksumMismatches {
                j.state = .skipped
                j.stateReason = .checksumMismatch
                j.uploadingGen = nil
            }

        case (.uploading, .stagingLost):
            j.state = .pending
            j.uploadingGen = nil

        case (.uploading, let .itemFailure(message, retryAt)), (.pending, let .itemFailure(message, retryAt)):
            j.uploadingGen = nil
            j.attempts += 1
            j.lastError = message
            j.nextAttemptAt = retryAt
            if j.attempts > maxAttempts {
                deferJob(&j, reason: .uploadFailures, now: now)
            } else {
                j.state = .pending
            }

        case (.pending, .exportGaveUp), (.uploading, .exportGaveUp):
            j.uploadingGen = nil
            deferJob(&j, reason: .exportFailures, now: now)

        case (.pending, .tooLargeForDisk), (.uploading, .tooLargeForDisk), (.deferred, .tooLargeForDisk):
            j.uploadingGen = nil
            deferJob(&j, reason: .tooLargeForDisk, now: now)

        case (.uploading, .destinationFailure(let message)), (.pending, .destinationFailure(let message)):
            j.state = .pending
            j.uploadingGen = nil
            j.lastError = message

        case (.deferred, .retryDeferred):
            j.state = .pending
            j.attempts = 0
            j.nextAttemptAt = nil
            if j.stateReason == .tooLargeForDisk {
                // Time spent waiting for disk space never counted toward the 30 days; a later
                // deferral for another reason starts its own window.
                j.deferredSince = nil
                j.stateReason = nil
            }

        case (.deferred, .deferralExpired):
            guard j.stateReason != .tooLargeForDisk else { return job }
            j.state = .skipped
            j.stateReason = .deferredTooLong

        case (.skipped, .retrySkipped):
            j.state = .pending
            j.stateReason = nil
            // A session kept from before the skip may belong to other content; a new one is cheap.
            j.sessionRef = nil
            j.sessionMd5 = nil
            j.attempts = 0
            j.mismatchCount = 0
            j.deferredSince = nil
            j.nextAttemptAt = nil

        case (.pending, let .permanentFailure(reason, message)), (.uploading, let .permanentFailure(reason, message)),
             (.deferred, let .permanentFailure(reason, message)):
            j.state = .skipped
            j.stateReason = reason
            j.lastError = message
            j.uploadingGen = nil

        case (_, .contentChanged(let target)):
            guard target > j.targetGen else { return job }
            j.targetGen = target
            if j.state == .done {
                j.state = .pending
                j.origin = .refresh
            }

        case (.done, .missingAtDestination):
            j.state = .missingRemote

        case (.pending, .missingAtDestination), (.uploading, .missingAtDestination):
            // A new generation was going to replace a file that is no longer there: the owner
            // decides, as for any missing file (FR-47), instead of retrying a replace that cannot work.
            guard j.doneGen > 0, j.remoteId != nil else { throw JobTransitionError.invalid(from: job.state, event: "missingAtDestination") }
            j.state = .missingRemote
            j.uploadingGen = nil
            j.sessionRef = nil
            j.sessionMd5 = nil
            j.nextAttemptAt = nil

        case (.missingRemote, .foundAgain):
            // The file is the one uploaded at `doneGen`; a newer generation still has to replace it.
            if j.doneGen < j.targetGen {
                j.state = .pending
                j.origin = .refresh
            } else {
                j.state = .done
            }

        case (.missingRemote, .reuploadConfirmed):
            j.state = .pending
            j.origin = .reupload
            j.remoteId = nil
            j.uploadedHash = nil
            j.sessionRef = nil
            j.sessionMd5 = nil
            j.doneGen = 0
            j.attempts = 0
            j.mismatchCount = 0

        case (.pending, .cancel), (.deferred, .cancel):
            j.state = .cancelled

        case (.cancelled, .reinstate(let origin)):
            j.state = .pending
            j.origin = origin
            j.attempts = 0
            j.nextAttemptAt = nil
            j.deferredSince = nil
            j.stateReason = nil

        default:
            throw JobTransitionError.invalid(from: job.state, event: String(describing: event))
        }
        return j
    }

    private static func deferJob(_ j: inout UploadJob, reason: JobStateReason, now: Date) {
        j.state = .deferred
        j.stateReason = reason
        if j.deferredSince == nil { j.deferredSince = now }
        j.nextAttemptAt = now.addingTimeInterval(deferredRetryInterval)
    }

    /// Desired job produced by eligibility (8.8) for upsert.
    public struct Desired: Hashable, Sendable {
        public var identity: JobIdentity
        public var origin: JobOrigin
        /// For resource jobs, the resource's `contentGen`; for sidecars, their own generation.
        public var targetGen: Int

        public init(identity: JobIdentity, origin: JobOrigin, targetGen: Int) {
            self.identity = identity
            self.origin = origin
            self.targetGen = targetGen
        }
    }

    /// 8.3 "Upsert": insert, reinstate a cancelled job, or raise `targetGen` of a live job.
    /// Returns nil when nothing changes. Repeated calls with the same input are idempotent.
    public static func upsert(existing: UploadJob?, desired: Desired, now: Date) -> UploadJob? {
        guard var job = existing else {
            return UploadJob(destinationId: desired.identity.destinationId, assetKey: desired.identity.assetKey,
                             resType: desired.identity.resType, origin: desired.origin, targetGen: desired.targetGen,
                             updatedAt: now)
        }
        switch job.state {
        case .cancelled:
            job = (try? apply(.reinstate(origin: desired.origin), to: job, now: now)) ?? job
            if desired.targetGen > job.targetGen { job.targetGen = desired.targetGen }
            return job
        case .skipped, .missingRemote:
            return nil
        case .pending, .uploading, .done, .deferred:
            guard desired.targetGen > job.targetGen else { return nil }
            return try? apply(.contentChanged(targetGen: desired.targetGen), to: job, now: now)
        }
    }

    /// Narrowing (FR-06, 8.3): cancel every job of an asset at a destination only when all of
    /// them are still `pending`/`deferred`/`cancelled`. Returns the jobs to write (empty = none).
    public static func cancelAll(_ jobs: [UploadJob], now: Date) -> [UploadJob] {
        guard jobs.allSatisfy({ [.pending, .deferred, .cancelled].contains($0.state) }) else { return [] }
        return jobs.compactMap { $0.state == .cancelled ? nil : try? apply(.cancel, to: $0, now: now) }
    }

    /// Ready to upload: pending, due, and the staged generation is at least the target.
    public static func isReady(_ job: UploadJob, resource: ResourceRecord?, now: Date) -> Bool {
        guard job.state == .pending, (job.nextAttemptAt ?? .distantPast) <= now else { return false }
        if job.resType.isSidecar { return true }
        guard let resource else { return false }
        return resource.stagingState == .ready && resource.stagingGen >= job.targetGen
    }
}
