import Foundation
import PhotoVaultCore

/// What the read half of a round did: Photos classification, the import stage, exports into staging.
struct ReadPass: Sendable {
    var classified = 0
    var export = ExportPassResult()
    /// Stages of the classify and export steps that did work.
    var stageWork = 0

    /// An export pass cut short by a pause or a waiting command counts as progress, so the cycle reaches its next pass
    /// boundary (which serves the command or ends the cycle as paused) instead of ending as drained.
    var progress: Int { classified + stageWork + export.exported + export.skippedByRule + (export.yielded ? 1 : 0) }
}

/// A round's read half and its upload pass, run side by side.
struct OverlappedPass: Sendable {
    var read = ReadPass()
    var uploaded = UploadPassResult()
}

private enum OverlappedPart: Sendable {
    case read(ReadPass)
    case uploaded(UploadPassResult)
}

/// The middle of a cycle round. Downloads and uploads use different directions of the link, so a round reads the next
/// files (a cloud import's reads and the exports into staging) while the upload pass sends what is already staged, and a
/// cloud-to-cloud import takes about as long as the slower direction instead of both added up.
///
/// The round's end is the barrier that bounds the look-ahead: the read half reads at most one import batch per round and
/// its exports stop at the staging limit (`ResourceGuard`), so it is never more than one batch ahead of an upload pass.
/// Uploads free staging file by file, which lets the exporter admit more in the same round.
///
/// Nothing beside the upload pass changes the plan of a job that may be in flight: the read half only adds assets and jobs,
/// re-counts days (a placement that changes under an upload is queued as a move by the upload's commit), and stages files.
/// Import cancels, which cancel pending jobs, are settled between rounds.
extension SyncCoordinator {
    /// Runs the read half and, when `gate` is given, the upload pass side by side, and returns when both are done. The first
    /// error of either half cancels the other and ends the round; an upload cut off this way stays `uploading` and is
    /// settled by `StartupRecovery.resolveInterrupted` like any interrupted upload.
    /// - Parameter readFirst: run the upload pass after the read half instead (new Photos assets keep their priority).
    func overlappedPass(_ trigger: SyncTrigger, uploads gate: UploadGate?, readFirst: Bool = false) async throws -> OverlappedPass {
        if readFirst {
            var pass = OverlappedPass(read: try await readPass(trigger))
            if let gate { pass.uploaded = try await uploader.runPass(gate: gate) }
            return pass
        }
        return try await withThrowingTaskGroup(of: OverlappedPart.self) { group in
            if let gate {
                group.addTask { [uploader] in .uploaded(try await uploader.runPass(gate: gate)) }
            }
            group.addTask { .read(try await self.readPass(trigger)) }
            var pass = OverlappedPass()
            for try await part in group {
                switch part {
                case .read(let read): pass.read = read
                case .uploaded(let uploaded): pass.uploaded = uploaded
                }
            }
            return pass
        }
    }

    /// Steps 3 and 4: Photos classification, the import stage (step `.classify`), exports into staging.
    private func readPass(_ trigger: SyncTrigger) async throws -> ReadPass {
        var read = ReadPass()
        read.classified = try await classifier.runPass().classified
        read.stageWork += try await runStages(.classify, trigger)
        read.export = try await exporter.runPass()
        read.stageWork += try await runStages(.export, trigger)
        return read
    }
}

extension CycleReport {
    mutating func add(_ uploaded: UploadPassResult) {
        self.uploaded += uploaded.uploaded
        uploadedByDestination.merge(uploaded.perDestination, uniquingKeysWith: +)
    }
}
