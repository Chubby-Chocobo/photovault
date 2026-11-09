import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// What a file of an import is compared on to find out whether it is already backed up.
struct ImportCandidate: Sendable {
    var key: AssetKey
    var sha256: String
    var creationDate: Date?
    var mediaType: MediaType
    var originalFilename: String
    var pixelWidth: Int
    var pixelHeight: Int
    var duration: Double
}

/// Decides in the ingest transaction whether an imported file is already backed up: the same bytes
/// (by key or by the hash of a resource), or the same photo as a live asset that is not exported yet
/// (same capture second, same file stem, same size or duration).
enum ImportDedupe {
    /// Capture dates this close count as the same second (EXIF has whole seconds, Photos has fractions).
    static let dateTolerance: TimeInterval = 1
    static let durationTolerance: Double = 0.5

    /// The live asset that already covers the file, or nil when it is new (or comes back from a removed import).
    static func check(_ db: Database, _ candidate: ImportCandidate, timeZone: TimeZone) throws -> AssetKey? {
        // The same bytes were imported before: still live means covered; removed means it comes back.
        if let existing = try AssetRepository.fetch(db, key: candidate.key) { return existing.deletedAt == nil ? candidate.key : nil }
        if let match = try AssetRepository.liveAsset(db, withResourceSHA256: candidate.sha256) { return match }
        return try fingerprintMatch(db, candidate, timeZone: timeZone)
    }

    private static func fingerprintMatch(_ db: Database, _ candidate: ImportCandidate, timeZone: TimeZone) throws -> AssetKey? {
        guard let date = candidate.creationDate else { return nil }
        let days = Set([-dateTolerance, dateTolerance].map { ArchiveDay(date: date.addingTimeInterval($0), timeZone: timeZone).description })
        let stem = NameStemBuilder.originalStem(of: candidate.originalFilename).lowercased()
        let rows = try Row.fetchAll(db, sql: """
            SELECT asset_key, creation_date, pixel_width, pixel_height, duration FROM asset
            WHERE creation_day IN (\(days.map { _ in "?" }.joined(separator: ","))) AND deleted_at IS NULL
            """, arguments: StatementArguments(Array(days)))
        for row in rows {
            guard let created: Date = row["creation_date"], abs(created.timeIntervalSince(date)) <= dateTolerance,
                  sameSize(candidate, width: row["pixel_width"], height: row["pixel_height"], duration: row["duration"]),
                  let key = AssetKey(rawValue: row["asset_key"]) else { continue }
            let descriptors = try ResourceRepository.fetchAll(db, key: key).map(\.descriptor)
            guard let primary = ResourcePlanner.primary(of: descriptors) else { continue }
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
