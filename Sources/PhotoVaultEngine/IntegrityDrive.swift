import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Where an expected Drive item stands. A file that sits under a trashed folder is the business of
/// the folder-trash flow (the owner restores the folder); it is neither present nor missing.
enum DriveItemPresence: Sendable {
    case present, gone, underTrashedFolder
}

/// The account listing of one check, with the walk up to a trashed ancestor.
struct DriveListing: Sendable {
    var items: [String: RemoteItem] = [:]

    private func hasTrashedAncestor(_ item: RemoteItem) -> Bool {
        var current = item.parentIds.first.flatMap { items[$0] }
        var hops = 0
        while let ancestor = current, hops < 64 {
            if ancestor.trashed { return true }
            current = ancestor.parentIds.first.flatMap { items[$0] }
            hops += 1
        }
        return false
    }

    /// nil when the listing does not show the item at all.
    func presence(of id: String) -> DriveItemPresence? {
        guard let item = items[id] else { return nil }
        if hasTrashedAncestor(item) { return .underTrashedFolder }
        return item.trashed ? .gone : .present
    }

    /// The path from `rootId` down to the item, so that it can be told whether it is part of that root.
    func isUnder(root rootId: String, _ item: RemoteItem) -> Bool {
        var current = item
        var hops = 0
        while hops < 64 {
            guard let parent = current.parentIds.first else { return false }
            if parent == rootId { return true }
            guard let next = items[parent] else { return false }
            current = next
            hops += 1
        }
        return false
    }
}

extension IntegrityChecker {
    func checkDrive(_ record: DestinationRecord, destination: any Destination) async throws -> IntegrityReport {
        var report = IntegrityReport()
        // The database is read first, then the destination is listed: a file that finished after
        // the snapshot is not part of the check, and one that is in the snapshot but not in the
        // listing is asked for by id before it counts as missing.
        let id = record.id
        let jobs = try await doneJobs(id)
        let knownShortcuts = try await liveShortcuts(id)
        var listing = DriveListing()
        for try await item in destination.list(under: nil) {
            try Task.checkCancellation()
            listing.items[item.remoteId] = item
        }
        var resolved: [String: DriveItemPresence] = [:]
        func presence(_ remoteId: String) async throws -> DriveItemPresence {
            if let known = resolved[remoteId] { return known }
            let value = try await resolvePresence(remoteId, destination, listing)
            resolved[remoteId] = value
            return value
        }
        report.checked = jobs.count
        var gone: [DoneJob] = []
        var present: [JobIdentity] = []
        for job in jobs {
            switch try await presence(job.remoteId) {
            case .gone: gone.append(job)
            case .present: present.append(job.identity)
            case .underTrashedFolder: continue
            }
        }
        report.missing = try await markMissing(gone).count
        try await recordChecked(present.map { ($0, .intact) })
        try await healReturned(id, presence: presence)
        try await reconcileShortcuts(
            record, destination: destination, known: knownShortcuts, listing: listing, presence: presence, report: &report)
        return report
    }

    private func resolvePresence(_ remoteId: String, _ destination: any Destination, _ listing: DriveListing) async throws -> DriveItemPresence {
        if let listed = listing.presence(of: remoteId) { return listed }
        return try await probePresence(remoteId, destination, listing)
    }

    /// The listing did not show the item: ask for it by id (and, when it is trashed, for its
    /// parents, to tell its own trash from a trashed folder above it). Errors other than
    /// "not found" end the check.
    private func probePresence(_ remoteId: String, _ destination: any Destination, _ listing: DriveListing) async throws -> DriveItemPresence {
        guard let item = try await probe(remoteId, destination) else { return .gone }
        guard item.trashed else { return .present }
        var parentId = item.parentIds.first
        var hops = 0
        while let current = parentId, hops < 64 {
            let parent: RemoteItem?
            if let listed = listing.items[current] { parent = listed } else { parent = try await probe(current, destination) }
            guard let parent else { break }
            if parent.trashed { return .underTrashedFolder }
            parentId = parent.parentIds.first
            hops += 1
        }
        return .gone
    }

    private func probe(_ remoteId: String, _ destination: any Destination) async throws -> RemoteItem? {
        do {
            return try await destination.probe(remoteId: remoteId)
        } catch DestinationError.notFound {
            return nil
        }
    }

    private func liveShortcuts(_ id: DestinationID) async throws -> [ShortcutRecord] {
        try await env.store.read { db in
            try [ShortcutState.done, .movePending].flatMap { try ShortcutRepository.fetch(db, destinationId: id, state: $0) }
        }
    }

    /// A file that was missing and is back (the owner restored it) is done again.
    private func healReturned(_ id: DestinationID, presence: (String) async throws -> DriveItemPresence) async throws {
        let missing = try await env.store.read { db in try JobRepository.fetch(db, state: .missingRemote, destinationId: id) }
        var back: [UploadJob] = []
        for job in missing {
            guard let remoteId = job.remoteId, try await presence(remoteId) == .present else { continue }
            back.append(job)
        }
        try await markHealed(back)
    }

    func markHealed(_ jobs: [UploadJob]) async throws {
        guard !jobs.isEmpty else { return }
        let now = env.clock.now
        try await env.store.write { db in
            for job in jobs {
                guard let current = try JobRepository.fetch(db, identity: job.identity), current.state == .missingRemote else { continue }
                _ = try JobRepository.apply(db, .foundAgain, to: job.identity, now: now)
                try IntegrityCheckRepository.record(db, identity: job.identity, result: .intact, at: now)
                // Sidecars, views and descriptions may have changed while the file was away.
                try DirtyQueue.mark(db, [.sidecar, .view, .description], asset: job.assetKey)
            }
        }
    }

    /// After the owner restored the root or a folder: files marked missing that are present again
    /// are done again at once, without waiting for the next scheduled check. A listing answers for
    /// most; the rest is asked for by id. Failures are not fatal: the next check heals as well.
    func healMissing(_ id: DestinationID, destination: any Destination) async {
        do {
            let missing = try await env.store.read { db in try JobRepository.fetch(db, state: .missingRemote, destinationId: id) }
            guard !missing.isEmpty else { return }
            var listing = DriveListing()
            for try await item in destination.list(under: nil) {
                try Task.checkCancellation()
                listing.items[item.remoteId] = item
            }
            var back: [UploadJob] = []
            for job in missing {
                guard let remoteId = job.remoteId else { continue }
                if try await resolvePresence(remoteId, destination, listing) == .present { back.append(job) }
            }
            try await markHealed(back)
        } catch is CancellationError {
            return
        } catch {
            env.log.log(.notice, category: "integrity", "heal after restore failed type=\(type(of: error))")
        }
    }

    /// Shortcuts the owner deleted stay deleted (`userRemoved`); app-made shortcuts of the current
    /// root that the database does not know are trashed. Only shortcuts, never files or folders.
    private func reconcileShortcuts(
        _ record: DestinationRecord, destination: any Destination, known: [ShortcutRecord], listing: DriveListing,
        presence: (String) async throws -> DriveItemPresence, report: inout IntegrityReport
    ) async throws {
        let id = record.id
        var ownerRemoved: [ShortcutRecord] = []
        for shortcut in known {
            guard let shortcutId = shortcut.shortcutId, try await presence(shortcutId) == .gone else { continue }
            ownerRemoved.append(shortcut)
        }
        let removed = ownerRemoved
        if !removed.isEmpty {
            report.shortcutsRemoved = try await env.store.write { db in
                var changed = 0
                for var shortcut in removed {
                    // Only a shortcut that is still the one that was checked.
                    guard let current = try ShortcutRepository.fetch(db, destinationId: id, view: shortcut.view, assetKey: shortcut.assetKey),
                          current.shortcutId == shortcut.shortcutId, [.done, .movePending].contains(current.state) else { continue }
                    shortcut.state = .userRemoved
                    try ShortcutRepository.save(db, shortcut)
                    changed += 1
                }
                return changed
            }
        }
        guard let viewing = destination as? any ViewDestination, let rootId = record.config.driveRootId, !rootId.isEmpty else { return }
        let knownIds: Set<String> = try await env.store.read { db in
            Set(try String.fetchAll(db, sql: "SELECT shortcut_id FROM shortcut WHERE destination_id = ? AND shortcut_id IS NOT NULL", arguments: [id.rawValue]))
        }
        // The listing covers the whole account: shortcuts of another root are not this app's to judge.
        let strays = listing.items.values.filter {
            $0.kind == .shortcut && !$0.trashed && $0.appProperties[AppPropertyKey.view] != nil
                && !knownIds.contains($0.remoteId) && listing.isUnder(root: rootId, $0)
        }.sorted { $0.remoteId < $1.remoteId }.prefix(Self.strayShortcutCap)
        for stray in strays {
            do {
                try await viewing.trashShortcut(remoteId: stray.remoteId)
                report.shortcutsTrashed += 1
            } catch DestinationError.notFound {
                continue
            }
        }
    }
}
