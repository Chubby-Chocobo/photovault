import Foundation
import PhotoVaultCore
import PhotoVaultStore

extension ImportStage {
    /// Records the files of the folder as import items (idempotent: a second listing adds only new files).
    func list(_ source: SourceRecord, _ folder: any FolderImportSource) async throws -> Bool {
        let entries: [FolderFileEntry]
        do {
            entries = try await folder.listFiles()
        } catch SourceError.accessRevoked {
            try await holdForSignIn(source.id)
            return true
        } catch is SourceError {
            try await hold(source.id)
            return true
        }
        let items = entries.map { entry in
            let ignored = FolderItemGrouper.isIgnored(relativePath: entry.relativePath)
            return ImportItem(
                sourceId: source.id, relativePath: entry.relativePath, groupKey: FolderItemGrouper.groupKey(relativePath: entry.relativePath),
                uti: entry.uti, sizeBytes: entry.sizeBytes, createdAtFS: entry.creationDate, modifiedAtFS: entry.modificationDate,
                state: ignored ? .unsupported : .pending, reason: ignored ? "companion" : nil)
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
}
