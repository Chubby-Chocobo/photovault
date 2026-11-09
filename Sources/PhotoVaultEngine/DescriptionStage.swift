import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Step 7, description part (FR-43): keeps the Drive `description` of backup files equal to
/// `Camera: … · Lens: … · Place: …` when device names or places change. Only destinations that
/// manage metadata (`RootManaging`) and support descriptions take part; files whose text did not
/// change are not touched.
struct DescriptionStage: CycleStage {
    let env: EngineEnvironment
    let resourceGuard: ResourceGuard
    var step: CycleStep { .sidecarsAndViews }

    private struct Target: Sendable {
        var record: DestinationRecord
        var destination: any RootManaging
    }

    func run(trigger: SyncTrigger) async throws -> Bool {
        let targets = try await descriptionTargets()
        guard !targets.isEmpty else {
            // Without a destination that keeps descriptions the queue is useless; a Drive added later queues a sweep.
            if try await !hasDescriptionDestination() {
                try await env.store.write { db in
                    try DirtyQueue.clear(db, .description, ids: try DirtyQueue.pending(db, .description, limit: 100_000))
                }
            }
            return false
        }
        var worked = false
        var seen = Set<String>()
        while true {
            try Task.checkCancellation()
            let limit = 100 + seen.count
            let ids: [String] = try await env.store.write { db in
                try DirtyQueue.promoteSweep(db, .description, limit: 100)
                return try DirtyQueue.pending(db, .description, limit: limit)
            }.filter { !seen.contains($0) }
            if ids.isEmpty { return worked }
            seen.formUnion(ids)
            var finished: [String] = []
            for id in ids {
                guard let key = AssetKey(rawValue: id) else {
                    finished.append(id)
                    continue
                }
                var complete = true
                for target in targets {
                    switch try await refresh(key, target) {
                    case .updated: worked = true
                    case .unchanged: break
                    case .retryLater: complete = false
                    }
                }
                if complete { finished.append(id) }
            }
            let cleared = finished
            try await env.store.write { db in try DirtyQueue.clear(db, .description, ids: cleared) }
        }
    }

    private func hasDescriptionDestination() async throws -> Bool {
        for record in try await env.store.read({ db in try DestinationRepository.fetchAll(db) }) {
            if let destination = await env.destinations.destination(for: record.id), destination.capabilities.supportsDescription,
               destination is any RootManaging { return true }
        }
        return false
    }

    private func descriptionTargets() async throws -> [Target] {
        let records = try await env.store.read { db in try DestinationRepository.fetchAll(db).filter(\.acceptsUploads) }
        var targets: [Target] = []
        for record in records {
            guard let destination = await env.destinations.destination(for: record.id), destination.capabilities.supportsDescription,
                  let managing = destination as? any RootManaging else { continue }
            targets.append(Target(record: record, destination: managing))
        }
        return targets
    }

    private enum Outcome { case updated, unchanged, retryLater }

    private func refresh(_ key: AssetKey, _ target: Target) async throws -> Outcome {
        let snapshot = await env.settingsSnapshot()
        let id = target.record.id
        let loaded: (text: String, recorded: String?, files: [String])? = try await env.store.read { db in
            guard let asset = try AssetRepository.fetch(db, key: key) else { return nil }
            // No parts left: an empty text clears what was written before (a Place: that must go).
            let text = try OrganizationLookups.descriptionText(db, asset: asset, settings: snapshot.settings) ?? ""
            let files = try JobRepository.fetchAll(db, assetKey: key)
                .filter { $0.destinationId == id && $0.state == .done && !$0.resType.isSidecar }.compactMap(\.remoteId)
            return (text, try DescriptionState.recorded(db, destinationId: id, key: key), files)
        }
        guard let loaded, !loaded.files.isEmpty, loaded.recorded != loaded.text else { return .unchanged }
        // Nothing was ever written: an empty text has nothing to clear.
        if loaded.text.isEmpty, loaded.recorded == nil { return .unchanged }
        for remoteId in loaded.files {
            guard await resourceGuard.admitMetadataWrite() else { return .retryLater }
            do {
                try await target.destination.updateMetadata(remoteId: remoteId, description: loaded.text, appProperties: [:])
            } catch DestinationError.notFound {
                continue
            } catch let error as DestinationError {
                env.log.log(.notice, category: "description", "description update failed error=\(error)")
                return .retryLater
            }
        }
        let text = loaded.text
        try await env.store.write { db in try DescriptionState.record(db, destinationId: id, key: key, text: text) }
        return .updated
    }
}
