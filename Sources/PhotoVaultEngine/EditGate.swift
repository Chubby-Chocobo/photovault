import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Step 5 of the cycle (FR-46): decides, outside the change transaction, whether an updated asset
/// has a new edit worth exporting. The transaction that ingested the change only set
/// `edit_check_pending`.
/// - no adjustments now → nothing to do; a revert keeps the edited file already backed up;
/// - the hash of `.adjustmentData` equals the stored one → no export;
/// - a different hash → `content_gen` of the edited resources goes up, their jobs follow through
///   the upsert and the edited file is replaced in place (created when missing);
/// - when Photos gives no hash, the modification date stands in for it, and the export it causes is
///   paid for from the backfill bucket.
struct EditGate: Sendable {
    let env: EngineEnvironment
    let resourceGuard: ResourceGuard

    private enum Decision {
        case clear
        case wait
        case changed(hash: String)
    }

    private static let batch = 50
    private static let defaultExportEstimate: Int64 = 8 << 20

    /// Returns the number of assets whose edited resources were bumped.
    func runPass() async throws -> Int {
        var bumped = 0
        var seen = Set<AssetKey>()
        while true {
            try Task.checkCancellation()
            let want = Self.batch + seen.count
            let assets = try await env.store.read { db in
                try String.fetchAll(db, sql: """
                    SELECT asset_key FROM asset WHERE edit_check_pending = 1 ORDER BY asset_key LIMIT ?
                    """, arguments: [want]).compactMap(AssetKey.init(rawValue:)).compactMap { try AssetRepository.fetch(db, key: $0) }
            }.filter { !seen.contains($0.assetKey) }
            if assets.isEmpty { return bumped }
            for asset in assets {
                seen.insert(asset.assetKey)
                switch try await decide(asset) {
                case .wait: continue
                case .clear: try await finish(asset, newHash: nil)
                case .changed(let hash):
                    if try await finish(asset, newHash: hash) { bumped += 1 }
                }
            }
        }
    }

    private func decide(_ asset: AssetRecord) async throws -> Decision {
        guard asset.deletedAt == nil, asset.sourceId == .photos, asset.hasAdjustments else { return .clear }
        let hash: String?
        do {
            hash = try await env.photos.adjustmentDataHash(localId: asset.localId)
        } catch {
            if error is EngineAbort || error is CancellationError { throw error }
            env.log.log(.notice, category: "editgate", "adjustment hash unavailable; will retry")
            return .wait
        }
        if let hash { return hash == asset.adjustmentHash ? .clear : .changed(hash: hash) }
        let marker = Self.modificationMarker(asset)
        if marker == asset.adjustmentHash { return .clear }
        let key = asset.assetKey
        let estimate = try await env.store.read { db in
            try ResourceRepository.fetchAll(db, key: key).filter { $0.type.isEdited }.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? Self.defaultExportEstimate) }
        }
        return await resourceGuard.tryConsumeBackfill(bytes: max(estimate, Self.defaultExportEstimate)) ? .changed(hash: marker) : .wait
    }

    static func modificationMarker(_ asset: AssetRecord) -> String {
        "mod:" + String(format: "%.3f", asset.modificationDate?.timeIntervalSince1970 ?? 0)
    }

    /// Commits the decision; false when the asset changed again meanwhile (it stays pending).
    @discardableResult
    private func finish(_ checked: AssetRecord, newHash: String?) async throws -> Bool {
        let snapshot = await env.settingsSnapshot()
        let env = env
        return try await env.store.write { db in
            guard var asset = try AssetRepository.fetch(db, key: checked.assetKey), asset.editCheckPending,
                  asset.modificationDate == checked.modificationDate else { return false }
            asset.editCheckPending = false
            guard let newHash else {
                try AssetRepository.upsert(db, asset, timeZone: snapshot.timeZone)
                return false
            }
            asset.adjustmentHash = newHash
            try AssetRepository.upsert(db, asset, timeZone: snapshot.timeZone)
            var bumped = false
            for resource in try ResourceRepository.fetchAll(db, key: asset.assetKey)
            where resource.type.isEdited && (resource.exportCount > 0 || resource.stagingState != .none) {
                _ = try ResourceRepository.bumpContentGen(db, key: asset.assetKey, type: resource.type)
                bumped = true
            }
            let context = try env.context(db, snapshot)
            try EligibilityService.recompute(db, asset: asset, context: context, extensions: [SidecarPlanner()])
            return bumped
        }
    }
}

struct EditGateStage: CycleStage {
    let gate: EditGate
    var step: CycleStep { .editGate }
    func run(trigger: SyncTrigger) async throws -> Bool { try await gate.runPass() > 0 }
}
