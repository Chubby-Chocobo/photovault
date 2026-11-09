import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Writes the asset and resource rows of one imported file group. An imported asset behaves like a
/// photo just added to Photos: a final category, `inserted_at` at ingest time, then the normal
/// finalize step (placement, day counts, jobs).
enum ImportIngest {
    struct Input: Sendable {
        var draft: AssetDraft
        var inspected: [String: InspectedFile]
        var creationDate: Date?
        var sourceId: SourceID
    }

    /// - Returns: the asset's key, and whether it came back from an earlier cancelled or removed import.
    static func ingest(
        _ db: Database, _ input: Input, key: AssetKey, albumTitles: [String], context: PipelineContext
    ) throws -> (key: AssetKey, revived: Bool) {
        let primary = input.draft.primary
        let metadata = input.inspected[primary.file.relativePath]?.metadata ?? .empty
        let locator = ImportLocator(sourceId: input.sourceId, relativePath: primary.file.relativePath)
        var record: AssetRecord
        let revived: Bool
        if var existing = try AssetRepository.fetch(db, key: key) {
            // The same bytes were imported before and removed: bring the asset back, keeping its placement.
            existing.deletedAt = nil
            existing.sourceId = input.sourceId
            existing.localId = locator.localId
            existing.lastSeenAt = context.now
            record = existing
            revived = true
        } else {
            let hasRaw = input.draft.members.contains { $0.file.isRaw }
            var subtypes = input.draft.subtypes
            if metadata.isScreenshot { subtypes.insert(.photoScreenshot) }
            let result = CategoryClassifier.classify(
                mediaType: input.draft.mediaType, subtypes: subtypes, hasRaw: hasRaw, albumTitles: albumTitles,
                settings: context.settings, headerMetadata: metadata.capture)
            // New content counts as new arrivals for destinations that only back up what comes next.
            let insertedAt = context.destinations.compactMap(\.baselineAt).reduce(context.now, max)
            record = AssetRecord(
                assetKey: key, localId: locator.localId, creationDate: input.creationDate, mediaType: input.draft.mediaType,
                mediaSubtypes: subtypes, category: result.category, categoryReason: result.reason, categoryProvisional: false,
                location: metadata.location, geoCell: metadata.location.map(GeoCell.init), pixelWidth: metadata.pixelWidth,
                pixelHeight: metadata.pixelHeight, duration: metadata.duration, cameraMake: metadata.capture.make,
                cameraModel: metadata.capture.model, lensModel: metadata.capture.lensModel, insertedAt: insertedAt,
                firstSeenAt: context.now, lastSeenAt: context.now, sourceId: input.sourceId)
            revived = false
        }
        try AssetRepository.upsert(db, record, timeZone: context.timeZone)
        for member in input.draft.members {
            try ResourceRepository.upsert(db, ResourceRecord(
                assetKey: key, type: member.type, isRaw: member.file.isRaw, originalFilename: member.file.originalFilename,
                uti: member.file.uti, sizeBytes: input.inspected[member.file.relativePath]?.size,
                // The hash read now is what the export must reproduce.
                sha256: input.inspected[member.file.relativePath]?.sha256))
        }
        return (key, revived)
    }
}
