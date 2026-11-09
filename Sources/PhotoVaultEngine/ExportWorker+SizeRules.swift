import Foundation
import PhotoVaultCore
import PhotoVaultStore

extension ExportWorker {
    /// Skips the jobs of destinations whose size cap the file exceeds (FR-33).
    func skipOversized(key: AssetKey, type: ResourceType, size: Int64, destinations: [DestinationRecord], force: Bool = false) async throws {
        let oversized = Set(destinations.filter { ($0.rules.skipLargerThanBytes ?? .max) < size || (force && $0.rules.skipLargerThanBytes != nil) }.map(\.id))
        guard !oversized.isEmpty else { return }
        let now = env.clock.now
        try await env.store.write { db in
            try EngineQueries.apply(
                db, .permanentFailure(.tooLargeForRule, message: "larger than destination limit"),
                key: key, type: type, states: [.pending], destinations: oversized, now: now)
        }
    }

    // MARK: tooLargeForDisk

    /// FR-31. The mark is on the resource, so a job that appears later for it (another destination,
    /// a wider rule) is deferred too and shows in the counts instead of waiting for ever. The
    /// resource is tried again when the free space covers the bytes it reached (its size when
    /// known) plus the margin, or after 24 hours at the latest.
    func revisitTooLarge() async throws {
        let free = try? env.disk.capacity(of: env.stagingDirectory).available
        let now = env.clock.now
        try await env.store.write { db in
            for resource in try EngineQueries.tooLargeResources(db) {
                let key = resource.assetKey
                let type = resource.type
                let fits = free.map {
                    DiskGuardPolicy.mayRetryTooLarge(freeBytes: $0, knownSizeBytes: resource.sizeBytes ?? resource.bytesReceivedAtCancel)
                } ?? false
                if fits || (resource.nextExportAttemptAt.map { $0 <= now } ?? false) {
                    try EngineQueries.clearTooLarge(db, key: key, type: type)
                    try EngineQueries.apply(db, .retryDeferred, key: key, type: type, states: [.deferred], now: now)
                } else {
                    try EngineQueries.apply(db, .tooLargeForDisk, key: key, type: type, states: [.pending], now: now)
                }
            }
        }
    }
}
