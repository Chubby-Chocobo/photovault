import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// Choosing the next export: candidates in priority order, the owner's skips (sign-in, cancelled import), the size rules and
/// the admission by `ResourceGuard` (staging limit, disk, power, backfill rate).
extension ExportWorker {
    enum Step {
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

    func dispatchNext(excluding: Set<String>) async throws -> Step {
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
            if signInDeferred.contains(asset.sourceId) || interrupts.isCancelRequested(asset.sourceId) { return .held(candidate.id) }
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
                    isPrimary: candidate.isPrimary, settings: settings,
                    isBackfill: !candidate.row.origins.isEmpty && candidate.row.origins.allSatisfy { $0 == .backfill || $0 == .destinationBackfill }))
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
}
