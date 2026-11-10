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
                    UPDATE asset SET placement_category = NULL, placement_day = NULL, name_stem = NULL, placed_at = NULL,
                        place_slot = NULL
                    WHERE asset_key = ?
                    """, arguments: [key])
                try db.execute(sql: "DELETE FROM name_alloc WHERE asset_key = ?", arguments: [key])
            }
        }
    }

    // MARK: Folders

    /// `remote_folder` rows, promoted days and the owner's device-group names (step 3).
    struct FolderTotals: Sendable, Equatable {
        var written = 0
        var conflicts = 0
    }

    @discardableResult
    func writeFolders(_ folders: [RemoteFolderEntry], listedIds: Set<String> = []) async throws -> FolderTotals {
        let id = record.id
        var unique: [String: RemoteFolderEntry] = [:]
        for folder in folders.sorted(by: { $0.remoteId < $1.remoteId }) where unique[folder.logicalPath] == nil { unique[folder.logicalPath] = folder }
        let ordered = unique.values.sorted { $0.logicalPath < $1.logicalPath }
        let now = env.clock.now
        let log = env.log
        return try await env.store.write { db in
            var totals = FolderTotals()
            for folder in ordered {
                // A row whose folder is still listed is never re-pointed; only a stale one (a restored backup) is.
                if let held = try RemoteFolderRepository.fetch(db, destinationId: id, logicalPath: folder.logicalPath)?.remoteId,
                   held != folder.remoteId, listedIds.contains(held) {
                    totals.conflicts += 1
                    log.log(.notice, category: "recovery", "destination=\(id) kept a folder row that points at another listed folder")
                    continue
                }
                let sharing = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM remote_folder WHERE destination_id = ? AND remote_id = ? AND logical_path != ?
                    """, arguments: [id.rawValue, folder.remoteId, folder.logicalPath]) ?? 0
                if sharing > 0 {
                    totals.conflicts += 1
                    log.log(.notice, category: "recovery", "destination=\(id) refused a folder row that would share a remote id")
                    continue
                }
                try RemoteFolderRepository.save(db, RemoteFolder(
                    destinationId: id, logicalPath: folder.logicalPath, remoteId: folder.remoteId,
                    displayName: folder.displayName, created: true))
                totals.written += 1
                if let day = folder.day {
                    if let slot = folder.slot {
                        try Self.adoptSlotFolder(db, day: day, slot: slot, placeName: folder.placeName, now: now)
                    } else {
                        try Self.adoptDay(db, day: day, placeName: folder.placeName, now: now)
                    }
                }
                let parts = folder.logicalPath.split(separator: "/")
                if parts.count == 3, parts[0] == "view", parts[1] == ViewKind.byDevice.rawValue {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO device_group (group_id, display_name) VALUES (?, ?)",
                        arguments: [String(parts[2]), folder.displayName])
                }
            }
            return totals
        }
    }

    /// An extra folder of a split day exists: the day is promoted and the folder is a known slot.
    private static func adoptSlotFolder(_ db: Database, day: ArchiveDay, slot: String, placeName: String?, now: Date) throws {
        try db.execute(sql: "INSERT INTO day_stat (day, count) VALUES (?, 0) ON CONFLICT(day) DO NOTHING", arguments: [day.description])
        try DayStatRepository.promote(db, day: day, now: now)
        try db.execute(sql: """
            INSERT OR IGNORE INTO day_place (day, slot, place_key, place_name) VALUES (?, ?, NULL, ?)
            """, arguments: [day.description, slot, placeName])
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

    func writeFiles(_ files: [RecoveredFile], daysWithRows: Set<ArchiveDay> = []) async throws -> FileTotals {
        var totals = FileTotals()
        let located = try await foldersOfAssets(files)
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
                    switch try Self.write(db, file, record: record, context: context, days: &days, located: located, daysWithRows: daysWithRows) {
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

    /// The day folder each asset's files sit in at this destination: the folder of its primary file,
    /// else the one holding most of its files (a tie goes to the main folder).
    private func foldersOfAssets(_ files: [RecoveredFile]) async throws -> [AssetKey: LocatedAsset] {
        let grouped = Dictionary(grouping: files, by: \.assetKey)
        return try await env.store.read { db in
            var result: [AssetKey: LocatedAsset] = [:]
            for (key, group) in grouped {
                let located = group.compactMap { file -> (type: ResourceType, place: LocatedAsset)? in
                    guard let parent = file.entry.parentLogical, let parsed = DynamicLayout.parseCameraDay(parent) else { return nil }
                    return (file.resType, LocatedAsset(day: parsed.day, slot: parsed.slot))
                }
                guard !located.isEmpty else { continue }
                let primary = ResourcePlanner.primary(of: try ResourceRepository.fetchAll(db, key: key).map(\.descriptor))?.type
                if let primary, let hit = located.first(where: { $0.type == primary }) {
                    result[key] = hit.place
                    continue
                }
                var counts: [LocatedAsset: Int] = [:]
                for item in located { counts[item.place, default: 0] += 1 }
                let best = counts.values.max() ?? 0
                let top = counts.filter { $0.value == best }.keys
                result[key] = top.first { $0.slot == nil } ?? top.sorted { ($0.slot ?? "") < ($1.slot ?? "") }.first
            }
            return result
        }
    }

    struct LocatedAsset: Hashable, Sendable {
        var day: ArchiveDay
        var slot: String?
    }

    private static func write(
        _ db: Database, _ file: RecoveredFile, record: DestinationRecord, context: PipelineContext, days: inout Set<ArchiveDay>,
        located: [AssetKey: LocatedAsset], daysWithRows: Set<ArchiveDay>
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
        // The slot comes from the folder the files are in: when the placement was read from the files, or when
        // the day was never split in this database (a restored older backup). Otherwise the database decides.
        if let place = located[file.assetKey], let day = placed.placement?.day.archiveDay, day == place.day {
            let adoptedNow = asset.placement == nil && placed.placement != nil
            if (adoptedNow || (asset.placeSlot == nil && !daysWithRows.contains(day))) && placed.placeSlot != place.slot {
                try AssetPlacementRepository.setPlaceSlot(db, key: file.assetKey, slot: place.slot)
                placed.placeSlot = place.slot
            }
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
                message: tr(
                    vi: "Một file khôi phục có dung lượng khác với sidecar; cần xác nhận trước khi upload lại",
                    en: "A recovered file has a different size from its sidecar; confirmation is needed before uploading again")))
        }
        try JobRepository.save(db, &job)
        if !file.resType.isSidecar {
            try restoreLostInputs(db, file, size: item.size)
        }
        if job.state == .done, placed.placement != nil, let from = job.remoteLogicalParent {
            let target = LayoutResolver.parentLogical(try LayoutResolver.chain(db, asset: placed, layout: context.layout))
            try MoveJobPlanner.enqueueMove(db, identity: identity, from: from, to: target, now: context.now)
        }
        return suspect ? .suspect : .applied
    }

    /// What the lost database knew and the destination still tells: the size, and the hashes and camera
    /// fields the sidecar lists. Only empty values are filled, so the sidecar built next matches the one
    /// at the destination when nothing else changed.
    private static func restoreLostInputs(_ db: Database, _ file: RecoveredFile, size: Int64?) throws {
        let key = file.assetKey.rawValue
        if let size {
            try db.execute(
                sql: "UPDATE resource SET size_bytes = ? WHERE asset_key = ? AND res_type = ? AND size_bytes IS NULL",
                arguments: [size, key, file.resType.rawValue])
        }
        try db.execute(sql: """
            UPDATE resource SET md5 = COALESCE(md5, ?), sha256 = COALESCE(sha256, ?)
            WHERE asset_key = ? AND res_type = ? AND (md5 IS NULL OR sha256 IS NULL)
            """, arguments: [file.entry.contentMd5, file.entry.contentSha256, key, file.resType.rawValue])
        if let camera = file.entry.camera {
            try db.execute(sql: """
                UPDATE asset SET camera_make = COALESCE(camera_make, ?), camera_model = COALESCE(camera_model, ?),
                    lens_model = COALESCE(lens_model, ?) WHERE asset_key = ?
                """, arguments: [camera.make, camera.model, camera.lens, key])
        }
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
