import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// Failure handling of one attempt, strictly by `ErrorClassifier` (spec 8.14).
extension UploadAttempt {
    /// Applies an event, ignoring a transition that is no longer valid (the job moved on).
    func applyIfValid(_ event: JobEvent) async throws {
        do {
            try await apply(event)
        } catch is JobTransitionError {
            env.logJob(.notice, "upload", jobId: ready.job.id, "transition no longer valid")
        } catch StoreError.notFound {
            env.logJob(.notice, "upload", jobId: ready.job.id, "job no longer exists")
        }
    }

    // MARK: Errors (spec 8.14)

    func handleFailure(_ error: any Error) async throws -> UploadOutcome {
        if error is UploadedFileGone {
            env.logJob(.notice, "upload", jobId: ready.job.id, "uploaded file is gone; waiting for the owner")
            try await applyIfValid(.missingAtDestination)
            return .skipped
        }
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
                try await FolderGone.markBranchMissing(env, destinationId: record.id, logicalPath: path)
                try await applyIfValid(.destinationFailure(message: failure.description))
                return .requeued
            }
            return try await itemFailure(failure.description)
        case .itemLevel, .transient:
            return try await itemFailure(failure.description)
        }
    }

    func itemFailure(_ message: String) async throws -> UploadOutcome {
        let current = try await env.store.read { db in try JobRepository.fetch(db, identity: identity) }
        let delay = Backoff().delay(forAttempt: current?.attempts ?? 0)
        try await applyIfValid(.itemFailure(message: message, retryAt: env.clock.now.addingTimeInterval(delay)))
        return .requeued
    }
}

/// The file a new generation should replace is no longer at the destination.
struct UploadedFileGone: Error {}
