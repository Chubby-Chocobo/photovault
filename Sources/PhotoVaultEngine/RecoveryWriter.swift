import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Spec 8.15 steps 3, 5 and 6: writes what recovery learned into the database. Every function is
/// idempotent, so a recovery that was interrupted simply runs again. Nothing here talks to the
/// destination.
struct RecoveryWriter: Sendable {
    let env: EngineEnvironment
    let record: DestinationRecord
    let timeZone: TimeZone

    private static let chunk = 200

    // MARK: Placements

    /// Placements made by the scan after a database loss exist only in the database: no file carries
    /// them yet. They are released so the placements read from the destination can be adopted
    /// without name clashes; a released asset is placed again afterwards. Placements with a file
    /// anywhere (done, uploading, missing, or a known remote id) are history and stay.
    func releaseUnconfirmedPlacements() async throws {
        try await env.store.write { db in
            let keys = try String.fetchAll(db, sql: """
                SELECT a.asset_key FROM asset a
                WHERE a.placement_category IS NOT NULL AND NOT EXISTS (
                    SELECT 1 FROM upload_job j WHERE j.asset_key = a.asset_key
                    AND (j.state IN ('done', 'uploading', 'missingRemote') OR j.remote_id IS NOT NULL))
                """)
            for key in keys {
                try db.execute(sql: """
                    UPDATE asset SET placement_category = NULL, placement_day = NULL, name_stem = NULL, placed_at = NULL
                    WHERE asset_key = ?
                    """, arguments: [key])
                try db.execute(sql: "DELETE FROM name_alloc WHERE asset_key = ?", arguments: [key])
            }
        }
    }

    // MARK: Folders

    /// `remote_folder` rows, promoted days and the owner's device-group names (step 3).
    @discardableResult
    func writeFolders(_ folders: [RemoteFolderEntry]) async throws -> Int {
        let id = record.id
        var unique: [String: RemoteFolderEntry] = [:]
        for folder in folders.sorted(by: { $0.remoteId < $1.remoteId }) where unique[folder.logicalPath] == nil { unique[folder.logicalPath] = folder }
        let ordered = unique.values.sorted { $0.logicalPath < $1.logicalPath }
        let now = env.clock.now
        try await env.store.write { db in
            for folder in ordered {
                try RemoteFolderRepository.save(db, RemoteFolder(
                    destinationId: id, logicalPath: folder.logicalPath, remoteId: folder.remoteId,
                    displayName: folder.displayName, created: true))
                if let day = folder.day { try Self.adoptDay(db, day: day, placeName: folder.placeName, now: now) }
                let parts = folder.logicalPath.split(separator: "/")
                if parts.count == 3, parts[0] == "view", parts[1] == ViewKind.byDevice.rawValue {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO device_group (group_id, display_name) VALUES (?, ?)",
                        arguments: [String(parts[2]), folder.displayName])
                }
            }
        }
        return ordered.count
    }

    /// A day folder exists: the day is promoted for good and keeps the folder's place name (FR-83).
    private static func adoptDay(_ db: Database, day: ArchiveDay, placeName: String?, now: Date) throws {
        try db.execute(sql: "INSERT INTO day_stat (day, count) VALUES (?, 0) ON CONFLICT(day) DO NOTHING", arguments: [day.description])
        try DayStatRepository.promote(db, day: day, now: now)
        guard let stat = try DayStatRepository.fetch(db, day: day), stat.placeState != .named else { return }
        try DayStatRepository.setPlace(
            db, day: day, state: placeName == nil ? .unnamed : .named, key: stat.placeKey, name: placeName)
    }

    // MARK: Files

    struct FileTotals: Sendable, Equatable {
        var applied = 0
        var suspect = 0
    }

    func writeFiles(_ files: [RecoveredFile]) async throws -> FileTotals {
        var totals = FileTotals()
        let settings = await env.settingsSnapshot()
        for start in stride(from: 0, to: files.count, by: Self.chunk) {
            try Task.checkCancellation()
            let batch = Array(files[start..<min(start + Self.chunk, files.count)])
            let env = env
            let record = record
            let part: FileTotals = try await env.store.write { db in
                let context = try env.context(db, settings)
                var days = Set<ArchiveDay>()
                var part = FileTotals()
                for file in batch {
                    switch try Self.write(db, file, record: record, context: context, days: &days) {
                    case .skipped: break
                    case .applied: part.applied += 1
                    case .suspect:
                        part.applied += 1
                        part.suspect += 1
                    }
                }
                try AssetFinalizer.recount(db, days: days, context: context)
                return part
            }
            totals.applied += part.applied
            totals.suspect += part.suspect
        }
        return totals
    }

    private enum WriteResult { case skipped, applied, suspect }

    private static func write(
        _ db: Database, _ file: RecoveredFile, record: DestinationRecord, context: PipelineContext, days: inout Set<ArchiveDay>
    ) throws -> WriteResult {
        guard let asset = try AssetRepository.fetch(db, key: file.assetKey) else { return .skipped }
        let identity = JobIdentity(destinationId: record.id, assetKey: file.assetKey, resType: file.resType)
        let existing = try JobRepository.fetch(db, identity: identity)
        // A transfer in flight finishes by itself.
        if existing?.state == .uploading { return .skipped }
        let resource = file.resType.isSidecar ? nil : try ResourceRepository.fetch(db, key: file.assetKey, type: file.resType)
        if !file.resType.isSidecar, resource == nil { return .skipped }

        if let alias = file.alias { try AssetRepository.addAlias(db, alias: alias, to: file.assetKey) }
        var placed = asset
        if asset.placement == nil, let placement = try adoptPlacement(db, file, asset: asset, now: context.now) {
            placed.placement = placement
            if placement.category == .camera, let day = placement.day.archiveDay { days.insert(day) }
        }
        let item = file.entry.item
        var job = existing ?? UploadJob(
            destinationId: record.id, assetKey: file.assetKey, resType: file.resType, origin: .backfill,
            targetGen: resource?.contentGen ?? 1, updatedAt: context.now)
        let sameRemote = existing?.state == .done && existing?.remoteId == item.remoteId
        job.remoteId = item.remoteId
        job.remoteName = item.name
        job.remoteLogicalParent = file.entry.parentLogical ?? job.remoteLogicalParent
        job.uploadedHash = sameRemote ? (existing?.uploadedHash ?? file.entry.uploadedHash) : (file.entry.uploadedHash ?? existing?.uploadedHash)
        job.doneGen = max(existing?.doneGen ?? 0, 1)
        job.state = job.doneGen >= job.targetGen ? .done : .pending
        if job.state == .pending { job.origin = .refresh }
        job.stateReason = nil
        job.sessionRef = nil
        job.sessionMd5 = nil
        job.uploadingGen = nil
        job.attempts = 0
        job.mismatchCount = 0
        job.nextAttemptAt = nil
        job.deferredSince = nil
        job.lastError = nil
        job.updatedAt = context.now
        var suspect = false
        if let expected = file.entry.expectedSize, let actual = item.size, expected != actual {
            job.state = .missingRemote
            suspect = true
            try ActivityRepository.record(db, ActivityEvent(
                at: context.now, kind: .missingFile, destinationId: record.id, assetKey: file.assetKey,
                message: "Một file khôi phục có dung lượng khác với sidecar; cần xác nhận trước khi upload lại"))
        }
        try JobRepository.save(db, &job)
        if !file.resType.isSidecar, let size = item.size {
            try db.execute(
                sql: "UPDATE resource SET size_bytes = ? WHERE asset_key = ? AND res_type = ? AND size_bytes IS NULL",
                arguments: [size, file.assetKey.rawValue, file.resType.rawValue])
        }
        if job.state == .done, let placement = placed.placement, let from = job.remoteLogicalParent {
            let target = LayoutResolver.parentLogical(try LayoutResolver.chain(db, placement: placement, layout: context.layout))
            try MoveJobPlanner.enqueueMove(db, identity: identity, from: from, to: target, now: context.now)
        }
        return suspect ? .suspect : .applied
    }

    /// Step 5: the placement is whatever the file says: category and day from where it is and what
    /// it is called, the stem from its name (`name_alloc` records it so no new file reuses it).
    private static func adoptPlacement(_ db: Database, _ file: RecoveredFile, asset: AssetRecord, now: Date) throws -> Placement? {
        guard let name = file.entry.name, let parent = file.entry.parentLogical,
              let category = parent.split(separator: "/").first.flatMap({ AssetCategory(rawValue: String($0)) }) else { return nil }
        let day: PlacementDay
        if parent.hasSuffix("/unknown") || name.dateText == nil {
            day = .unknown
        } else if let text = name.dateText, let parsed = ArchiveDay(string: String(text.prefix(10))) {
            day = .day(parsed)
        } else {
            return nil
        }
        let key = NameSanitizer.collisionKey(name.fullStem)
        try db.execute(sql: """
            INSERT OR IGNORE INTO name_alloc (placement_category, placement_day, norm_stem, asset_key) VALUES (?, ?, ?, ?)
            """, arguments: [category.rawValue, day.description, key, asset.assetKey.rawValue])
        let owner = try String.fetchOne(db, sql: """
            SELECT asset_key FROM name_alloc WHERE placement_category = ? AND placement_day = ? AND norm_stem = ?
            """, arguments: [category.rawValue, day.description, key])
        // The stem belongs to another asset: this one gets a fresh stem later.
        guard owner == asset.assetKey.rawValue else { return nil }
        let placement = Placement(category: category, day: day, nameStem: name.fullStem)
        try db.execute(sql: """
            UPDATE asset SET placement_category = ?, placement_day = ?, name_stem = ?, placed_at = ? WHERE asset_key = ?
            """, arguments: [category.rawValue, day.description, name.fullStem, now, asset.assetKey.rawValue])
        return placement
    }

    // MARK: Shortcuts

    /// Step 6: shortcuts already at the destination join the `shortcut` table. They are held
    /// against trashing until their asset's view position can be computed (see `ViewPlanner`).
    @discardableResult
    func writeShortcuts(_ shortcuts: [RecoveredShortcut]) async throws -> Int {
        let id = record.id
        var count = 0
        for start in stride(from: 0, to: shortcuts.count, by: Self.chunk) {
            let batch = Array(shortcuts[start..<min(start + Self.chunk, shortcuts.count)])
            count += try await env.store.write { db in
                var written = 0
                for item in batch {
                    let entry = item.entry
                    let existing = try ShortcutRepository.fetch(db, destinationId: id, view: entry.view, assetKey: item.assetKey)
                    if existing?.shortcutId == entry.shortcutId, existing?.state == .done { continue }
                    if existing?.shortcutId != nil, existing?.shortcutId != entry.shortcutId, existing?.state == .done { continue }
                    if let alias = item.alias { try AssetRepository.addAlias(db, alias: alias, to: item.assetKey) }
                    try ShortcutRepository.save(db, ShortcutRecord(
                        destinationId: id, view: entry.view, assetKey: item.assetKey, targetId: entry.targetId,
                        shortcutId: entry.shortcutId, parentLogical: entry.parentLogical, state: .done))
                    try ViewHold.add(db, destinationId: id, view: entry.view, assetKey: item.assetKey)
                    written += 1
                }
                return written
            }
        }
        return count
    }
}
