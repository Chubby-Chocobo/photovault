import CryptoKit
import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// FR-76: path and size of every expected file, plus a re-hash of a deterministic 1 % sample
/// (at most 5 GB per run) to find bit rot. Everything goes through the destination's own API.
extension IntegrityChecker {
    static let sampleFraction = 0.01
    static let sampleByteCap: Int64 = 5 * 1024 * 1024 * 1024

    func checkLocal(_ record: DestinationRecord, destination: any Destination) async throws -> IntegrityReport {
        var report = IntegrityReport()
        let id = record.id
        let jobs = try await doneJobs(id)
        report.checked = jobs.count
        var missing: [JobIdentity] = []
        var intact: [(job: DoneJob, size: Int64)] = []
        for job in jobs {
            try Task.checkCancellation()
            guard let item = try await destination.probe(remoteId: job.remoteId), item.kind == .file else {
                report.missing += 1
                missing.append(job.identity)
                continue
            }
            if let expected = job.expectedSize, let actual = item.size, expected != actual {
                report.sizeMismatch += 1
                missing.append(job.identity)
            } else {
                intact.append((job, item.size ?? job.expectedSize ?? 0))
            }
        }
        if let reader = env.localContent {
            let seed = Self.seed(env.clock.now)
            for chosen in Self.sample(intact, seed: seed) {
                try Task.checkCancellation()
                guard let expected = chosen.job.uploadedHash else { continue }
                let actual = try await reader.sha256(destination: id, path: chosen.job.remoteId)
                report.hashed += 1
                if actual != expected {
                    report.hashMismatch += 1
                    missing.append(chosen.job.identity)
                }
            }
        }
        try await markMissing(missing)
        return report
    }

    /// The run date: the sample rotates daily, so the whole archive is covered over time.
    private static func seed(_ date: Date) -> String {
        String(Int(date.timeIntervalSince1970 / 86_400))
    }

    /// Files ranked by `SHA-256(seed, path)`; the first 1 % (at least one) that fits in the byte cap.
    static func sample(_ files: [(job: DoneJob, size: Int64)], seed: String) -> [(job: DoneJob, size: Int64)] {
        let eligible = files.filter { $0.job.uploadedHash != nil }
        guard !eligible.isEmpty else { return [] }
        let wanted = max(1, Int((Double(eligible.count) * sampleFraction).rounded(.up)))
        let ranked = eligible.map { file in
            (file, SHA256.hash(data: Data((seed + "\u{0}" + file.job.remoteId).utf8)).hexString)
        }.sorted { ($0.1, $0.0.job.remoteId) < ($1.1, $1.0.job.remoteId) }
        var chosen: [(job: DoneJob, size: Int64)] = []
        var bytes: Int64 = 0
        for (file, _) in ranked where chosen.count < wanted {
            guard bytes + file.size <= sampleByteCap else { continue }
            chosen.append(file)
            bytes += file.size
        }
        return chosen
    }
}
