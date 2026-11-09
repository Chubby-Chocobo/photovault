import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import UniformTypeIdentifiers

/// Runs the folder imports inside the cycle (spec 8.4, after classification): lists a folder, reads and
/// hashes its files group by group outside any transaction, then ingests each group in one
/// transaction so a crash leaves either the whole group or nothing. Bounded work per run.
struct ImportStage: CycleStage {
    let env: EngineEnvironment
    let extensions: [any JobPlanningExtension]
    var step: CycleStep { .classify }

    func run(trigger: SyncTrigger) async throws -> Bool {
        let open = try await env.store.read { db in
            try SourceRepository.fetchAll(db).filter { $0.kind == .localFolder && $0.status.isOpen }
        }
        var changed = false
        for source in open {
            try Task.checkCancellation()
            guard let folder = await env.sources.folder(for: source.id) else { continue }
            if try await advance(source, folder) { changed = true }
        }
        return changed
    }

    private func advance(_ source: SourceRecord, _ folder: any FolderImportSource) async throws -> Bool {
        switch source.status {
        case .offline: return try await resume(source, folder)
        case .scanning: return try await scan(source, folder)
        case .importing: return try await finishWhenDone(source)
        case .completed, .cancelled: return false
        }
    }

    // MARK: Availability

    /// An unreachable folder holds its own job only; it picks up again when the folder is back.
    private func resume(_ source: SourceRecord, _ folder: any FolderImportSource) async throws -> Bool {
        guard try await reachable(source, folder) else { return false }
        let status: SourceStatus = source.listedAt == nil ? .scanning : .importing
        try await setStatus(source.id, status, reason: nil)
        return true
    }

    /// False when the folder cannot be read now; the job is then marked offline.
    private func reachable(_ source: SourceRecord, _ folder: any FolderImportSource) async throws -> Bool {
        do {
            try await folder.probe()
            return true
        } catch let error as SourceError {
            if source.status != .offline { try await hold(source.id, error) }
            return false
        }
    }

    private func hold(_ id: SourceID, _ error: SourceError) async throws {
        try await setStatus(id, .offline, reason: "unavailable")
        env.log.log(.notice, category: "import", "source unavailable; import held")
    }

    private func setStatus(_ id: SourceID, _ status: SourceStatus, reason: String?) async throws {
        let now = env.clock.now
        try await env.store.write { db in
            // A cancel that landed meanwhile stays cancelled.
            guard let current = try SourceRepository.fetch(db, id: id)?.status, current.isOpen else { return }
            try SourceRepository.setStatus(db, id: id, status: status, reason: reason, now: now)
        }
    }

    // MARK: Listing

    private func scan(_ source: SourceRecord, _ folder: any FolderImportSource) async throws -> Bool {
        guard try await reachable(source, folder) else { return true }
        if source.listedAt == nil { return try await list(source, folder) }
        return try await ingestBatch(source, folder)
    }

    private func list(_ source: SourceRecord, _ folder: any FolderImportSource) async throws -> Bool {
        let entries: [FolderFileEntry]
        do {
            entries = try await folder.listFiles()
        } catch let error as SourceError {
            try await hold(source.id, error)
            return true
        }
        let items = entries.map { entry in
            ImportItem(
                sourceId: source.id, relativePath: entry.relativePath, groupKey: FolderItemGrouper.groupKey(relativePath: entry.relativePath),
                uti: entry.uti, sizeBytes: entry.sizeBytes, createdAtFS: entry.creationDate, modifiedAtFS: entry.modificationDate,
                state: FolderItemGrouper.isIgnored(relativePath: entry.relativePath) ? .unsupported : .pending,
                reason: FolderItemGrouper.isIgnored(relativePath: entry.relativePath) ? "companion" : nil)
        }
        let batch = max(1, env.tuning.importListBatch)
        let now = env.clock.now
        let id = source.id
        for start in stride(from: 0, to: items.count, by: batch) {
            let slice = Array(items[start..<min(start + batch, items.count)])
            let last = start + batch >= items.count
            try await env.store.write { db in
                try ImportItemRepository.insertIgnoring(db, slice)
                if last { try SourceRepository.setListed(db, id: id, now: now) }
            }
        }
        if items.isEmpty { try await env.store.write { db in try SourceRepository.setListed(db, id: id, now: now) } }
        return true
    }

    // MARK: Ingest

    private func ingestBatch(_ source: SourceRecord, _ folder: any FolderImportSource) async throws -> Bool {
        let id = source.id
        let limit = max(1, env.tuning.importBatchGroups)
        let groups = try await env.store.read { db in try ImportItemRepository.nextGroups(db, sourceId: id, limit: limit) }
        guard !groups.isEmpty else {
            try await setStatus(id, .importing, reason: nil)
            return true
        }
        let settings = await env.settingsSnapshot()
        var bytes: Int64 = 0
        for group in groups {
            try Task.checkCancellation()
            guard try await process(group, source: source, folder: folder, settings: settings) else { return true }
            bytes += group.reduce(0) { $0 + $1.sizeBytes }
            if bytes >= env.tuning.importBatchBytes { break }
        }
        return true
    }

    /// Reads the group's files, then ingests them. False when the folder went away or the read was cancelled.
    private func process(_ group: [ImportItem], source: SourceRecord, folder: any FolderImportSource, settings: SettingsSnapshot) async throws -> Bool {
        var inspected: [String: InspectedFile] = [:]
        var failed: [String: String] = [:]
        for item in group {
            let mediaType: MediaType = UTType(item.uti)?.conforms(to: .movie) == true ? .video : .image
            do {
                inspected[item.relativePath] = try await folder.inspect(
                    relativePath: item.relativePath, uti: item.uti, mediaType: mediaType, control: ExportControl())
            } catch let error as SourceError {
                switch error {
                case .unavailable:
                    try await hold(source.id, error)
                    return false
                case .cancelled: return false
                case .fileMissing, .fileChanged: failed[item.relativePath] = "missing"
                case .readFailed: failed[item.relativePath] = "read"
                }
            }
        }
        try env.reach(.afterImportInspectBeforeCommit)
        let inputs = Self.drafts(group, inspected: inspected, source: source, env: env, timeZone: settings.timeZone)
        let env = env
        let extensions = extensions
        let id = source.id
        let failures = failed
        try await env.store.write { db in
            guard try SourceRepository.fetch(db, id: id)?.status.isOpen == true else { return }
            let context = try env.context(db, settings)
            var dirty = Set<ArchiveDay>()
            for entry in inputs {
                try Self.commit(db, entry, context: context, extensions: extensions, dirty: &dirty)
            }
            for (path, reason) in failures {
                try ImportItemRepository.mark(db, sourceId: id, relativePath: path, state: .failed, assetKey: nil, isPrimary: false, dateSource: nil, reason: reason)
            }
            try AssetFinalizer.recount(db, days: dirty, context: context)
        }
        try env.reach(.afterImportGroupCommit)
        return true
    }

    // MARK: Group → assets

    struct Entry: Sendable {
        var input: ImportIngest.Input
        var dateSource: DateSource
        var albumTitles: [String]
        var candidate: ImportCandidate?
    }

    /// Pure: groups the inspected files into assets and decides each one's date.
    static func drafts(
        _ group: [ImportItem], inspected: [String: InspectedFile], source: SourceRecord, env: EngineEnvironment, timeZone: TimeZone
    ) -> [Entry] {
        let files = group.compactMap { item -> GroupInput? in
            guard let info = inspected[item.relativePath] else { return nil }
            let video = UTType(item.uti)?.conforms(to: .movie) == true
            return GroupInput(
                relativePath: item.relativePath, uti: item.uti, mediaType: video ? .video : .image,
                isRaw: !video && env.utiResolver.isRaw(item.uti), contentIdentifier: info.metadata.contentIdentifier)
        }
        let byPath = Dictionary(group.map { ($0.relativePath, $0) }) { first, _ in first }
        return FolderItemGrouper.group(files).map { draft in
            let primary = draft.primary
            let item = byPath[primary.file.relativePath]
            let info = inspected[primary.file.relativePath]
            let entry = FolderFileEntry(
                relativePath: primary.file.relativePath, uti: primary.file.uti, sizeBytes: item?.sizeBytes ?? 0,
                creationDate: item?.createdAtFS, modificationDate: item?.modifiedAtFS)
            let dated = ImportDatePolicy.captureDate(metadata: info?.metadata ?? .empty, entry: entry, archiveTimeZone: timeZone)
            let directories = primary.file.relativePath.split(separator: "/").dropLast().map(String.init)
            let key = info.flatMap { AssetKey.content(sha256: $0.sha256) }
            let candidate = key.map { key in
                ImportCandidate(
                    key: key, sha256: info?.sha256 ?? "", creationDate: dated.date, mediaType: draft.mediaType,
                    originalFilename: primary.file.originalFilename, pixelWidth: info?.metadata.pixelWidth ?? 0,
                    pixelHeight: info?.metadata.pixelHeight ?? 0, duration: info?.metadata.duration ?? 0)
            }
            return Entry(
                input: ImportIngest.Input(draft: draft, inspected: inspected, creationDate: dated.date, sourceId: source.id),
                dateSource: dated.source, albumTitles: directories, candidate: candidate)
        }
    }

    /// One asset: a duplicate marks its files, anything else becomes an asset that goes through the normal pipeline.
    private static func commit(
        _ db: Database, _ entry: Entry, context: PipelineContext, extensions: [any JobPlanningExtension], dirty: inout Set<ArchiveDay>
    ) throws {
        let sourceId = entry.input.sourceId
        let members = entry.input.draft.members
        let primaryPath = entry.input.draft.primary.file.relativePath
        guard let candidate = entry.candidate else {
            for member in members {
                try ImportItemRepository.mark(db, sourceId: sourceId, relativePath: member.file.relativePath, state: .failed, assetKey: nil, isPrimary: false, dateSource: nil, reason: "hash")
            }
            return
        }
        if let match = try ImportDedupe.check(db, candidate, timeZone: context.timeZone) {
            for member in members {
                try ImportItemRepository.mark(db, sourceId: sourceId, relativePath: member.file.relativePath, state: .duplicate, assetKey: match, isPrimary: false, dateSource: nil, reason: nil)
            }
            return
        }
        let result = try ImportIngest.ingest(db, entry.input, key: candidate.key, albumTitles: entry.albumTitles, context: context)
        for member in members {
            let isPrimary = member.file.relativePath == primaryPath
            try ImportItemRepository.mark(
                db, sourceId: sourceId, relativePath: member.file.relativePath, state: .imported, assetKey: result.key,
                isPrimary: isPrimary, dateSource: isPrimary ? entry.dateSource : nil, reason: nil)
        }
        try AssetFinalizer.finalize(db, key: result.key, context: context, dirtyDays: &dirty, extensions: extensions)
    }

    // MARK: Completion

    /// Done when every file was decided and no upload of the job is waiting or running. Written
    /// together with its one activity row.
    private func finishWhenDone(_ source: SourceRecord) async throws -> Bool {
        let id = source.id
        let now = env.clock.now
        return try await env.store.write { db in
            guard (try ImportItemRepository.counts(db, sourceId: id)[.pending] ?? 0) == 0,
                  try Bool.fetchOne(db, sql: """
                    SELECT NOT EXISTS(SELECT 1 FROM asset a JOIN upload_job j ON j.asset_key = a.asset_key
                                      WHERE a.source_id = ? AND j.state IN ('pending', 'uploading'))
                    """, arguments: [id.rawValue]) == true else { return false }
            return try ImportCompletion.finish(db, id: id, as: .completed, now: now)
        }
    }
}
