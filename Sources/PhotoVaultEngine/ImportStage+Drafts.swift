import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import UniformTypeIdentifiers

extension ImportStage {
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
    static func commit(
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
