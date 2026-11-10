import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import UniformTypeIdentifiers

extension ImportStage {
    /// What became of one group in this pass.
    enum GroupOutcome: Equatable { case committed, waitingForDisk, waitingForProvider(isFresh: Bool), stop }

    func ingestBatch(_ source: SourceRecord, _ folder: any FolderImportSource) async throws -> Bool {
        let id = source.id
        let limit = max(1, env.tuning.importBatchGroups)
        let groups = try await nextGroups(id, limit: limit)
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
        var troubled = 0
        loop: for group in groups {
            try Task.checkCancellation()
            switch try await process(group, source: source, folder: folder, settings: settings) {
            case .stop: return true
            case .waitingForDisk: break
            case .waitingForProvider(let isFresh):
                // Fresh groups failing one after another mean the provider is in trouble: stop asking it for now.
                // Groups that were already failing do not count; they are only tried again, never first.
                guard isFresh else { break }
                troubled += 1
                if troubled >= ImportHolds.troubleStreak {
                    pauseBriefly(id)
                    break loop
                }
            case .committed:
                troubled = 0
                bytes += group.reduce(0) { $0 + $1.sizeBytes }
                if bytes >= env.tuning.importBatchBytes { break loop }
            }
        }
        try await showDiskWait(source)
        return true
    }

    /// Groups that never failed come first, in group order; then the failing ones whose retry time has come,
    /// soonest first. A few stubborn files can therefore never keep the rest from being read.
    private func nextGroups(_ id: SourceID, limit: Int) async throws -> [[ImportItem]] {
        let now = env.clock.now
        let diskBlocked = holds.diskBlockedGroups(id, now: now)
        let failing = holds.failingGroups(id, now: now)
        let fresh = try await env.store.read { db in
            try ImportItemRepository.nextGroups(db, sourceId: id, limit: limit, excluding: diskBlocked.union(failing.all))
        }
        guard fresh.count < limit, !failing.due.isEmpty else { return fresh }
        let due = Set(failing.due)
        let retries = try await env.store.read { db in
            try ImportItemRepository.nextGroups(db, sourceId: id, limit: limit - fresh.count, excluding: diskBlocked, only: due)
        }
        let order = Dictionary(uniqueKeysWithValues: failing.due.enumerated().map { ($1, $0) })
        return fresh + retries.sorted { (order[$0.first?.groupKey ?? ""] ?? 0) < (order[$1.first?.groupKey ?? ""] ?? 0) }
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
        var givenUp = false
        let groupKey = group.first?.groupKey ?? ""
        for item in group {
            let mediaType: MediaType = UTType(item.uti)?.conforms(to: .movie) == true ? .video : .image
            // A cloud file is downloaded to scratch space first; do not start when it would eat the reserve.
            if source.kind != .localFolder, !hasRoomToDownload(item.sizeBytes, settings: settings) {
                holds.blockForDisk(source.id, group: groupKey, now: env.clock.now)
                env.log.log(.info, category: "import", "import file waits for disk room")
                return .waitingForDisk
            }
            let transfer = env.transfers.begin(
                kind: .download(source.kind), fileName: (item.relativePath as NSString).lastPathComponent,
                accountEmail: source.config.account, bytesTotal: item.sizeBytes)
            defer { transfer.end() }
            let control = ExportControl()
            control.setProgress(transfer.sink)
            do {
                inspected[item.relativePath] = try await adapter {
                    try await folder.inspect(relativePath: item.relativePath, uti: item.uti, mediaType: mediaType, control: control)
                }
            } catch is AdapterFault {
                try await hold(source.id)
                return .stop
            } catch let error as SourceError {
                switch error {
                case .busy:
                    if !givenUp {
                        if let outcome = retryLater(source, group: groupKey) { return outcome }
                        givenUp = true
                    }
                    failed[item.relativePath] = "read"
                case .unavailable:
                    // A folder that no longer answers holds the whole job.
                    guard try await reachable(source, folder) else { return .stop }
                    // A Mac file that cannot be read is that file's problem. A cloud read fails on a dropped
                    // connection all the time; the file waits and is tried again.
                    if source.kind != .localFolder {
                        if !givenUp {
                            if let outcome = retryLater(source, group: groupKey) { return outcome }
                            givenUp = true
                        }
                    }
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
        if givenUp, !failed.isEmpty { env.log.log(.notice, category: "import", "import group unreadable for a day; marked failed") }
        try await commitGroup(group, inspected: inspected, failed: failed, source: source, settings: settings)
        holds.settled(source.id, group: groupKey)
        return .committed
    }

    /// Notes the failure: the group is left pending and tried again later, with a longer wait each time. Nil once
    /// it has failed often enough, for long enough, that it is given up (importing the folder again brings it back).
    /// The source's probe answered at the start of this pass, so the failure is the group's own, not an outage's.
    private func retryLater(_ source: SourceRecord, group: String) -> GroupOutcome? {
        let failure = holds.noteFailure(source.id, group: group, now: env.clock.now)
        if failure.giveUp { return nil }
        env.log.log(.info, category: "import", "source busy; import group waits")
        return .waitingForProvider(isFresh: failure.isFresh)
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
