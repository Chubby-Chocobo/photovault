import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// First half of "Dựng lại view": the database learns what the owner removed in Drive, so the
/// sweep that follows creates it again. View folders and shortcuts are the app's own, never backup
/// data. Only a definitive answer counts (not found, or trashed): an error says nothing about the
/// item, so the preparation stops and is repeated later, and nothing is created beside an item
/// that still exists.
struct ViewRebuildPreparation: Sendable {
    let env: EngineEnvironment
    let record: DestinationRecord
    let destination: any ViewDestination
    let ensurer: FolderEnsurer

    /// Returns false when the destination could not answer and the rebuild has to wait.
    func run() async throws -> Bool {
        do {
            try await forgetGoneFolders()
            try await resetShortcuts()
            return true
        } catch let error as DestinationError {
            env.log.log(.notice, category: "views", "rebuild waits: check failed error=\(error)")
            return false
        }
    }

    private func isGone(_ remoteId: String) async throws -> Bool {
        do {
            let item = try await destination.probe(remoteId: remoteId)
            return item == nil || item?.trashed == true
        } catch DestinationError.notFound {
            return true
        }
    }

    private func forgetGoneFolders() async throws {
        let id = record.id
        let folders = try await env.store.read { db in
            try RemoteFolderRepository.fetchAll(db, destinationId: id).filter { $0.logicalPath.hasPrefix("view") && $0.created }
        }
        for folder in folders {
            guard let remoteId = folder.remoteId else { continue }
            if try await isGone(remoteId) { try await ensurer.invalidate(logicalPath: folder.logicalPath) }
        }
    }

    /// A shortcut the owner deleted is made again; a `failed` one gets a fresh start: it is kept
    /// when it still exists, and made again when it does not.
    private func resetShortcuts() async throws {
        let id = record.id
        let rows = try await env.store.read { db in
            try [ShortcutState.done, .movePending, .failed].flatMap { try ShortcutRepository.fetch(db, destinationId: id, state: $0) }
        }
        guard !rows.isEmpty else { return }
        var listed = Set<String>()
        for try await item in destination.list(under: nil) where !item.trashed {
            try Task.checkCancellation()
            listed.insert(item.remoteId)
        }
        var gone: [ShortcutRecord] = []
        var revive: [ShortcutRecord] = []
        for row in rows {
            guard let shortcutId = row.shortcutId else {
                if row.state == .failed { gone.append(row) }
                continue
            }
            if listed.contains(shortcutId) {
                if row.state == .failed { revive.append(row) }
            } else if try await isGone(shortcutId) {
                gone.append(row)
            } else if row.state == .failed {
                revive.append(row)
            }
        }
        let forgotten = gone
        let kept = revive
        try await env.store.write { db in
            for snapshot in forgotten {
                guard var current = try Self.unchanged(db, snapshot) else { continue }
                current.state = .trashed
                current.shortcutId = nil
                current.attempts = 0
                try ShortcutRepository.save(db, current)
            }
            for snapshot in kept {
                guard var current = try Self.unchanged(db, snapshot) else { continue }
                current.state = .done
                current.attempts = 0
                try ShortcutRepository.save(db, current)
            }
        }
    }

    /// The row as it is now, only if it is still what the check looked at.
    private static func unchanged(_ db: Database, _ snapshot: ShortcutRecord) throws -> ShortcutRecord? {
        guard let current = try ShortcutRepository.fetch(db, destinationId: snapshot.destinationId, view: snapshot.view, assetKey: snapshot.assetKey),
              current.state == snapshot.state, current.shortcutId == snapshot.shortcutId else { return nil }
        return current
    }
}
