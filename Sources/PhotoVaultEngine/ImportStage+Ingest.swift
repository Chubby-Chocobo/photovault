import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import UniformTypeIdentifiers

extension ImportStage {

    func ingestBatch(_ source: SourceRecord, _ folder: any FolderImportSource) async throws -> Bool {
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
                    // One file that cannot be read is that file's problem; only a folder that no longer answers holds the job.
                    guard try await reachable(source, folder) else { return false }
                    failed[item.relativePath] = "read"
                case .accessRevoked, .cancelled: return false
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
                    key: key, sha256: info?.sha256 ?? "", creationDate: dated.date, dateSource: dated.source, mediaType: draft.mediaType,
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
        if case .duplicate(let match) = try ImportDedupe.check(db, candidate, importing: sourceId, timeZone: context.timeZone) {
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
}
