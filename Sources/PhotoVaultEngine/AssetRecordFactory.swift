import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Builds and refreshes `asset` and `resource` rows from Photos snapshots (spec 8.1, FR-10, FR-21).
enum AssetRecordFactory {
    static func key(for snapshot: AssetSnapshot) -> AssetKey {
        snapshot.cloudId.map(AssetKey.cloud) ?? .local(snapshot.localId)
    }

    static func newRecord(
        _ snapshot: AssetSnapshot, albumTitles: [String], insertedAt: Date?, context: PipelineContext
    ) -> AssetRecord {
        let result = CategoryClassifier.classify(
            mediaType: snapshot.mediaType, subtypes: snapshot.subtypes, hasRaw: snapshot.hasRaw,
            albumTitles: albumTitles, settings: context.settings, headerMetadata: nil)
        var record = AssetRecord(
            assetKey: key(for: snapshot), localId: snapshot.localId, cloudId: snapshot.cloudId,
            mediaType: snapshot.mediaType, category: result.category, categoryReason: result.reason,
            categoryProvisional: result.provisional, insertedAt: insertedAt, firstSeenAt: context.now, lastSeenAt: context.now)
        copyScanFields(snapshot, into: &record)
        return record
    }

    /// Refreshes the Photos-owned fields of an existing row. Category, placement, camera fields,
    /// `inserted_at` and `first_seen_at` are preserved (placement is fixed once).
    static func merged(_ existing: AssetRecord, with snapshot: AssetSnapshot, now: Date) -> AssetRecord {
        var record = existing
        // A changed modification date or a flipped adjustment flag queues the edit gate (FR-46); the
        // gate itself runs outside this transaction.
        if let new = snapshot.modificationDate, existing.modificationDate != new { record.editCheckPending = true }
        if existing.hasAdjustments != snapshot.hasAdjustments { record.editCheckPending = true }
        record.localId = snapshot.localId
        if record.cloudId == nil { record.cloudId = snapshot.cloudId }
        copyScanFields(snapshot, into: &record)
        record.lastSeenAt = now
        record.deletedAt = nil
        return record
    }

    private static func copyScanFields(_ snapshot: AssetSnapshot, into record: inout AssetRecord) {
        record.creationDate = snapshot.creationDate
        record.modificationDate = snapshot.modificationDate
        record.mediaType = snapshot.mediaType
        record.mediaSubtypes = snapshot.subtypes
        record.isHidden = snapshot.isHidden
        record.isFavorite = snapshot.isFavorite
        record.burstIdentifier = snapshot.burstIdentifier
        record.burstIsPick = snapshot.burstIsPick
        record.location = snapshot.location
        record.geoCell = snapshot.location.map(GeoCell.init)
        record.pixelWidth = snapshot.pixelWidth
        record.pixelHeight = snapshot.pixelHeight
        record.duration = snapshot.duration
        record.hasAdjustments = snapshot.hasAdjustments
    }

    /// One row per uploadable resource. Rows exist for every type the planner could ever plan, so
    /// widening a rule enqueues from the database without rescanning (FR-19).
    static func resourceRecords(_ snapshot: AssetSnapshot, key: AssetKey) -> [ResourceRecord] {
        snapshot.resources
            .filter { !ResourcePlanner.neverUploaded.contains($0.type) && !$0.type.isSidecar }
            .map { ResourceRecord(assetKey: key, type: $0.type, isRaw: $0.isRaw, originalFilename: $0.originalFilename, uti: $0.uti) }
    }

    /// Writes (or refreshes) the asset, its resources, aliases and album membership.
    /// - Returns: the stored row and whether the asset existed before.
    @discardableResult
    static func ingest(
        _ db: Database, _ snapshot: AssetSnapshot, albums: [AlbumMember.Membership], insertedAt: Date?,
        stampInsertedOnExisting: Bool, context: PipelineContext
    ) throws -> (record: AssetRecord, existed: Bool) {
        let direct = try AssetRepository.find(db, localId: snapshot.localId, cloudId: nil)
        let existing = try direct ?? snapshot.cloudId.flatMap { try AssetRepository.find(db, localId: nil, cloudId: $0) }
        var record: AssetRecord
        if var found = existing {
            let oldLocalId = found.localId
            let reattached = direct == nil
            if stampInsertedOnExisting, !reattached, found.insertedAt == nil { found.insertedAt = insertedAt }
            record = merged(found, with: snapshot, now: context.now)
            try AssetRepository.upsert(db, record, timeZone: context.timeZone)
            if oldLocalId != snapshot.localId { try AssetRepository.addAlias(db, alias: oldLocalId, to: record.assetKey) }
        } else {
            record = newRecord(snapshot, albumTitles: albums.map(\.title), insertedAt: insertedAt, context: context)
            try AssetRepository.upsert(db, record, timeZone: context.timeZone)
        }
        if !record.assetKey.isCloud, let cloud = snapshot.cloudId, record.cloudId == cloud {
            try AssetRepository.addAlias(db, alias: cloud, to: record.assetKey)
        }
        for resource in resourceRecords(snapshot, key: record.assetKey) { try ResourceRepository.upsert(db, resource) }
        if !albums.isEmpty || existing != nil {
            let members = albums.map { AlbumMember(albumLocalId: $0.id, albumTitle: $0.title, assetKey: record.assetKey) }
            try AssetRepository.setAlbums(db, for: record.assetKey, members: members)
        }
        return (record, existing != nil)
    }
}

extension AlbumMember {
    /// Album identity without the asset key, as read from the Photos source.
    struct Membership: Sendable, Hashable {
        var id: String
        var title: String
    }
}
