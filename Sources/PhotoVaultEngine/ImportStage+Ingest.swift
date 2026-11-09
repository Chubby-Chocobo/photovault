import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import UniformTypeIdentifiers

extension ImportStage {
    /// What became of one group in this pass.
    enum GroupOutcome { case committed, waiting, stop }

    func ingestBatch(_ source: SourceRecord, _ folder: any FolderImportSource) async throws -> Bool {
        let id = source.id
        let limit = max(1, env.tuning.importBatchGroups)
        let skipped = holds.blockedGroups(id, now: env.clock.now)
        let groups = try await env.store.read { db in try ImportItemRepository.nextGroups(db, sourceId: id, limit: limit, excluding: skipped) }
        guard !groups.isEmpty else {
            let pending = try await env.store.read { db in try ImportItemRepository.counts(db, sourceId: id)[.pending] ?? 0 }
            // Groups that wait for a retry keep the import open; nothing else is left to read now.
            guard pending == 0 else {
                try await showDiskWait(source)
                return false
            }
            try await setStatus(id, .importing, reason: nil)
            return true
        }
        let settings = await env.settingsSnapshot()
        var bytes: Int64 = 0
        var progressed = false
        var waited = false
        loop: for group in groups {
            try Task.checkCancellation()
            switch try await process(group, source: source, folder: folder, settings: settings) {
            case .stop: return true
            case .waiting: waited = true
            case .committed:
                progressed = true
                bytes += group.reduce(0) { $0 + $1.sizeBytes }
                if bytes >= env.tuning.importBatchBytes { break loop }
            }
        }
        try await showDiskWait(source)
        // Nothing could be read in this pass: back off instead of asking the provider again at once.
        if waited, !progressed { pauseBriefly(id) }
        return true
    }

    /// The row says why it is not moving while a file waits for room, and drops the reason once it fits.
    private func showDiskWait(_ source: SourceRecord) async throws {
        let waiting = holds.isWaitingForDisk(source.id, now: env.clock.now)
        let current = source.statusReason
        guard waiting != (current == SourceStatusReason.diskFull) else { return }
        guard current == nil || current == SourceStatusReason.diskFull else { return }
        let id = source.id
        let reason: String? = waiting ? SourceStatusReason.diskFull : nil
        try await env.store.write { db in
            guard let row = try SourceRepository.fetch(db, id: id), row.status == .scanning else { return }
            try SourceRepository.setStatusReason(db, id: id, reason: reason)
        }
    }

    /// Reads the group's files, then ingests them. A group that cannot be read now is left pending and skipped for a while.
    private func process(_ group: [ImportItem], source: SourceRecord, folder: any FolderImportSource, settings: SettingsSnapshot) async throws -> GroupOutcome {
        var inspected: [String: InspectedFile] = [:]
        var failed: [String: String] = [:]
        let groupKey = group.first?.groupKey ?? ""
        for item in group {
            let mediaType: MediaType = UTType(item.uti)?.conforms(to: .movie) == true ? .video : .image
            // A cloud file is downloaded to scratch space first; do not start when it would eat the reserve.
            if source.kind != .localFolder, !hasRoomToDownload(item.sizeBytes, settings: settings) {
                holds.block(source.id, group: groupKey, reason: .disk, now: env.clock.now)
                env.log.log(.info, category: "import", "import file waits for disk room")
                return .waiting
            }
            do {
                inspected[item.relativePath] = try await adapter {
                    try await folder.inspect(relativePath: item.relativePath, uti: item.uti, mediaType: mediaType, control: ExportControl())
                }
                holds.readable(source.id, path: item.relativePath)
            } catch is AdapterFault {
                try await hold(source.id)
                return .stop
            } catch let error as SourceError {
                switch error {
                case .busy:
                    if waitsForRetry(item, source: source, group: groupKey) { return .waiting }
                    failed[item.relativePath] = "read"
                case .unavailable:
                    // A folder that no longer answers holds the whole job.
                    guard try await reachable(source, folder) else { return .stop }
                    // A Mac file that cannot be read is that file's problem. A cloud read fails on a dropped
                    // connection all the time; the file waits and is tried again.
                    if source.kind != .localFolder, waitsForRetry(item, source: source, group: groupKey) { return .waiting }
                    failed[item.relativePath] = "read"
                case .accessRevoked:
                    try await holdForSignIn(source.id)
                    return .stop
                case .cancelled: return .stop
                case .fileMissing, .fileChanged: failed[item.relativePath] = "missing"
                case .readFailed: failed[item.relativePath] = "read"
                }
            }
        }
        try env.reach(.afterImportInspectBeforeCommit)
        try await commitGroup(group, inspected: inspected, failed: failed, source: source, settings: settings)
        return .committed
    }

    /// True when the group should wait for another try. False once the file has been unreadable for a day:
    /// it is then marked failed so the import can finish (importing the folder again brings it back).
    private func waitsForRetry(_ item: ImportItem, source: SourceRecord, group: String) -> Bool {
        let now = env.clock.now
        if holds.shouldGiveUp(source.id, path: item.relativePath, now: now) {
            holds.readable(source.id, path: item.relativePath)
            env.log.log(.notice, category: "import", "import file unreadable for a day; marked failed")
            return false
        }
        holds.block(source.id, group: group, reason: .busy, now: now)
        env.log.log(.info, category: "import", "source busy; import group waits")
        return true
    }

    private func commitGroup(
        _ group: [ImportItem], inspected: [String: InspectedFile], failed: [String: String], source: SourceRecord, settings: SettingsSnapshot
    ) async throws {
        let inputs = Self.drafts(group, inspected: inspected, source: source, env: env, timeZone: settings.timeZone)
        let env = env
        let extensions = extensions
        let id = source.id
        try await env.store.write { db in
            guard try SourceRepository.fetch(db, id: id)?.status.isOpen == true else { return }
            let context = try env.context(db, settings)
            var dirty = Set<ArchiveDay>()
            for entry in inputs {
                try Self.commit(db, entry, context: context, extensions: extensions, dirty: &dirty)
            }
            for (path, reason) in failed {
                try ImportItemRepository.mark(db, sourceId: id, relativePath: path, state: .failed, assetKey: nil, isPrimary: false, dateSource: nil, reason: reason)
            }
            try AssetFinalizer.recount(db, days: dirty, context: context)
        }
        try env.reach(.afterImportGroupCommit)
    }

    /// True when the scratch volume keeps its critical reserve after a download of `bytes`.
    private func hasRoomToDownload(_ bytes: Int64, settings: SettingsSnapshot) -> Bool {
        guard let free = try? env.disk.capacity(of: env.stagingDirectory).available else { return true }
        return free - bytes >= settings.settings.criticalWatermarkBytes
    }
}
