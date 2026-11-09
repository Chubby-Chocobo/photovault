import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// What a file of an import is compared on to find out whether it is already backed up.
struct ImportCandidate: Sendable {
    var key: AssetKey
    var sha256: String
    var creationDate: Date?
    /// Where the date came from; a file date says nothing about when the photo was taken.
    var dateSource: DateSource
    var mediaType: MediaType
    var originalFilename: String
    var pixelWidth: Int
    var pixelHeight: Int
    var duration: Double
}

enum ImportVerdict: Equatable {
    /// Not backed up: ingest it (this also brings back a removed import of the same bytes).
    case new
    /// Already backed up by this asset.
    case duplicate(AssetKey)
    /// The same bytes are live under an import that was cancelled: the new job takes the asset over.
    case takeOver
}

/// Decides in the ingest transaction whether an imported file is already backed up. The same bytes
/// (by key or by the hash of a resource) always decide. The fingerprint (same capture second, stem
/// and size) is only a stand-in for a hash that does not exist yet: it applies to a Photos asset
/// that has not been exported, and only when the file's own metadata gives the date. A distinct
/// file is never dropped on a guess; the cost of a wrong "new" is one extra upload.
enum ImportDedupe {
    /// Capture dates this close count as the same second (EXIF has whole seconds, Photos has fractions).
    static let dateTolerance: TimeInterval = 1
    static let durationTolerance: Double = 0.5

    static func check(_ db: Database, _ candidate: ImportCandidate, importing sourceId: SourceID, timeZone: TimeZone) throws -> ImportVerdict {
        if let existing = try AssetRepository.fetch(db, key: candidate.key) {
            guard existing.deletedAt == nil else { return .new }
            if existing.sourceId != sourceId, existing.sourceId != .photos,
               try SourceRepository.fetch(db, id: existing.sourceId).map({ $0.status == .cancelled }) ?? true {
                return .takeOver
            }
            return .duplicate(candidate.key)
        }
        if let match = try AssetRepository.liveAsset(db, withResourceSHA256: candidate.sha256) { return .duplicate(match) }
        if let match = try fingerprintMatch(db, candidate, timeZone: timeZone) { return .duplicate(match) }
        return .new
    }

    private static func fingerprintMatch(_ db: Database, _ candidate: ImportCandidate, timeZone: TimeZone) throws -> AssetKey? {
        guard candidate.dateSource != .fileDate, let date = candidate.creationDate else { return nil }
        let days = Set([-dateTolerance, dateTolerance].map { ArchiveDay(date: date.addingTimeInterval($0), timeZone: timeZone).description })
        let stem = NameStemBuilder.originalStem(of: candidate.originalFilename).lowercased()
        let rows = try Row.fetchAll(db, sql: """
            SELECT asset_key, creation_date, pixel_width, pixel_height, duration FROM asset
            WHERE creation_day IN (\(days.map { _ in "?" }.joined(separator: ","))) AND deleted_at IS NULL AND source_id = 'photos'
            """, arguments: StatementArguments(Array(days)))
        for row in rows {
            guard let created: Date = row["creation_date"], abs(created.timeIntervalSince(date)) <= dateTolerance,
                  sameSize(candidate, width: row["pixel_width"], height: row["pixel_height"], duration: row["duration"]),
                  let key = AssetKey(rawValue: row["asset_key"]) else { continue }
            let resources = try ResourceRepository.fetchAll(db, key: key)
            guard let primaryType = ResourcePlanner.primary(of: resources.map(\.descriptor))?.type,
                  let primary = resources.first(where: { $0.type == primaryType }),
                  primary.sha256 == nil else { continue }
            if NameStemBuilder.originalStem(of: primary.originalFilename).lowercased() == stem { return key }
        }
        return nil
    }

    /// Photos compare the pair in either order (orientation may swap it); videos compare the duration.
    /// An unknown size never matches.
    private static func sameSize(_ candidate: ImportCandidate, width: Int, height: Int, duration: Double) -> Bool {
        if candidate.mediaType == .video {
            return candidate.duration > 0 && abs(candidate.duration - duration) <= durationTolerance
        }
        guard candidate.pixelWidth > 0, candidate.pixelHeight > 0 else { return false }
        return (candidate.pixelWidth, candidate.pixelHeight) == (width, height) || (candidate.pixelWidth, candidate.pixelHeight) == (height, width)
    }
}
