import Foundation
import GRDB
import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultEngine
import PhotoVaultStore

/// Read-only database questions the screens ask. Plain SQL against the schema; nothing here writes
/// except the small kv helper at the end.
enum AppQueries {
    struct DeviceModel: Equatable, Sendable {
        var key: String
        var count: Int
    }

    struct DeviceGroupInfo: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        var models: [DeviceModel]
        var assetCount: Int { models.reduce(0) { $0 + $1.count } }
    }

    struct GeocodeProgress: Equatable, Sendable {
        var resolvedCells: Int
        var totalCells: Int
    }

    struct ViewCounts: Equatable, Sendable {
        var device: Int
        var place: Int
        var favorites: Int
        var lens: Int
        var files: Int
        var folders: Int
    }

    /// The groups the "By device" view uses: every camera model in the library, merged by stored assignment.
    static func deviceGroups(_ db: Database) throws -> [DeviceGroupInfo] {
        var assignment: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT make_model_key, group_id FROM device_model") {
            assignment[row["make_model_key"]] = row["group_id"]
        }
        var names: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT group_id, display_name FROM device_group") { names[row["group_id"]] = row["display_name"] }
        var groups: [String: DeviceGroupInfo] = [:]
        let rows = try Row.fetchAll(db, sql: """
            SELECT camera_make, camera_model, COUNT(*) AS n FROM asset
            WHERE camera_model IS NOT NULL AND category = 'camera' AND deleted_at IS NULL
            GROUP BY camera_make, camera_model
            """)
        for row in rows {
            let make: String? = row["camera_make"]
            let model: String? = row["camera_model"]
            guard !DeviceNameResolver.normalize(model).isEmpty else { continue }
            let key = DeviceNameResolver.key(make: make, model: model)
            let groupId = assignment[key] ?? DeviceNameResolver.groupId(forKey: key)
            let name = names[groupId] ?? DeviceNameResolver.bundled.displayName(make: make, model: model)
            var group = groups[groupId] ?? DeviceGroupInfo(id: groupId, name: name, models: [])
            group.models.append(DeviceModel(key: key, count: row["n"]))
            groups[groupId] = group
        }
        return groups.values.sorted { ($0.assetCount, $1.name) > ($1.assetCount, $0.name) }
    }

    static func geocodeProgress(_ db: Database) throws -> GeocodeProgress {
        let total = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT geo_cell) FROM asset WHERE geo_cell IS NOT NULL AND deleted_at IS NULL") ?? 0
        let resolved = try Int.fetchOne(db, sql: """
            SELECT COUNT(DISTINCT a.geo_cell) FROM asset a JOIN geo_cache g ON g.geo_cell = a.geo_cell
            WHERE a.deleted_at IS NULL
            """) ?? 0
        return GeocodeProgress(resolvedCells: resolved, totalCells: total)
    }

    /// Items the Drive tree holds now plus the shortcuts each view would add (FR-103 estimate).
    static func viewCounts(_ db: Database) throws -> ViewCounts {
        func count(_ sql: String) throws -> Int { try Int.fetchOne(db, sql: sql) ?? 0 }
        return ViewCounts(
            device: try count("SELECT COUNT(*) FROM asset WHERE category = 'camera' AND camera_model IS NOT NULL AND deleted_at IS NULL"),
            place: try count("SELECT COUNT(*) FROM asset WHERE geo_cell IS NOT NULL AND deleted_at IS NULL"),
            favorites: try count("SELECT COUNT(*) FROM asset WHERE is_favorite = 1 AND deleted_at IS NULL"),
            lens: try AssetRepository.countCameraWithLens(db),
            files: try count("SELECT COUNT(*) FROM upload_job WHERE destination_id = 'gdrive' AND state != 'cancelled'"),
            folders: try count("SELECT COUNT(*) FROM remote_folder WHERE destination_id = 'gdrive'"))
    }

    /// Asset counts behind the "~N asset" lines of the rule preview.
    static func ruleCounts(_ db: Database) throws -> [RuleKey: Int] {
        func count(_ clause: String) throws -> Int {
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE deleted_at IS NULL AND \(clause)") ?? 0
        }
        return [
            .camera: try count("category = 'camera'"), .screenshot: try count("category = 'screenshot'"),
            .saved: try count("category = 'saved'"), .photo: try count("media_type = 1"), .video: try count("media_type = 2"),
            .edited: try count("has_adjustments = 1"),
        ]
    }

    static func liveAssetCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE deleted_at IS NULL") ?? 0
    }

    static let lastIntegrityKey = "app_last_integrity_check"

    static func lastIntegrityCheck(_ db: Database) throws -> Date? { try KeyValueRepository.date(db, lastIntegrityKey) }

    static func recordIntegrityCheck(_ db: Database, at date: Date) throws {
        try KeyValueRepository.set(db, lastIntegrityKey, date)
    }

    static let accountChangePauseKey = "app_account_change_pause"

    /// How far an unfinished "Đổi tài khoản" got: `paused` before the new account was written to the
    /// Keychain, `committing` once that write may have happened.
    enum AccountChangeMarker: Int {
        case paused = 1
        case committing = 2
    }

    /// Set while "Đổi tài khoản" holds Drive paused, so a quit in the middle can be undone at the next launch.
    static func accountChangePause(_ db: Database) throws -> AccountChangeMarker? {
        try KeyValueRepository.int(db, accountChangePauseKey).flatMap(AccountChangeMarker.init(rawValue:))
    }

    static func setAccountChangePause(_ db: Database, _ marker: AccountChangeMarker?) throws {
        try KeyValueRepository.set(db, accountChangePauseKey, marker?.rawValue)
    }

    static func baselineTaken(_ db: Database) throws -> Bool {
        try KeyValueRepository.data(db, KeyValueRepository.Key.baselineToken) != nil
    }

    static func macDiskFullSince(_ db: Database) throws -> Date? { try KeyValueRepository.date(db, KeyValueRepository.Key.macDiskFullSince) }

    static func lastSuccessfulSync(_ db: Database) throws -> Date? { try KeyValueRepository.date(db, KeyValueRepository.Key.lastSuccessfulSyncAt) }
}
