import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

public enum DeviceGroupError: Error, Equatable, Sendable {
    /// Another group already has this name; merging the two is the suggested way out (FR-104).
    case duplicateName(existingGroupId: String)
    case emptyName
    case unknownGroup
}

/// Owner edits of the "By device" grouping (FR-104). A rename changes the folder name (the view
/// folders follow through the normal view pass); a merge assigns a camera model to another group,
/// which moves its shortcuts.
struct DeviceGroupService: Sendable {
    let env: EngineEnvironment

    private struct KnownGroup {
        var groupId: String
        var name: String
        var modelKeys: [String]
    }

    func rename(groupId: String, to proposed: String) async throws {
        let name = proposed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty else { throw DeviceGroupError.emptyName }
        try await env.store.write { db in
            let groups = try Self.knownGroups(db)
            let stored = try DeviceGroupRepository.group(db, id: groupId)
            guard let current = groups.first(where: { $0.groupId == groupId })
                ?? stored.map({ KnownGroup(groupId: $0.groupId, name: $0.displayName, modelKeys: []) })
            else { throw DeviceGroupError.unknownGroup }
            if let clash = groups.first(where: { $0.groupId != current.groupId && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                throw DeviceGroupError.duplicateName(existingGroupId: clash.groupId)
            }
            try db.execute(sql: """
                INSERT INTO device_group (group_id, display_name) VALUES (?, ?)
                ON CONFLICT(group_id) DO UPDATE SET display_name = excluded.display_name
                """, arguments: [groupId, name])
            try DirtyQueue.requestSweep(db, [.view, .sidecar, .description])
        }
    }

    /// Assigns the camera model `makeModelKey` to the group `groupId`.
    func merge(makeModelKey: String, into groupId: String) async throws {
        try await env.store.write { db in
            guard let target = try Self.knownGroups(db).first(where: { $0.groupId == groupId }) else { throw DeviceGroupError.unknownGroup }
            try DeviceGroupRepository.assign(db, makeModelKey: makeModelKey, groupId: groupId, defaultDisplayName: target.name)
            try DirtyQueue.requestSweep(db, [.view, .sidecar, .description])
        }
    }

    /// Groups as the view rules see them: stored groups and the default group of every camera model in the library.
    private static func knownGroups(_ db: Database) throws -> [KnownGroup] {
        var byModel: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT make_model_key, group_id FROM device_model") { byModel[row["make_model_key"]] = row["group_id"] }
        var names: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT group_id, display_name FROM device_group") { names[row["group_id"]] = row["display_name"] }
        var groups: [String: KnownGroup] = [:]
        let models = try Row.fetchAll(db, sql: """
            SELECT DISTINCT camera_make, camera_model FROM asset WHERE camera_model IS NOT NULL AND category = 'camera'
            """)
        for row in models {
            let make: String? = row["camera_make"]
            let model: String? = row["camera_model"]
            guard !DeviceNameResolver.normalize(model).isEmpty else { continue }
            let key = DeviceNameResolver.key(make: make, model: model)
            let groupId = byModel[key] ?? DeviceNameResolver.groupId(forKey: key)
            let name = names[groupId] ?? DeviceNameResolver.bundled.displayName(make: make, model: model)
            groups[groupId, default: KnownGroup(groupId: groupId, name: name, modelKeys: [])].modelKeys.append(key)
        }
        for (groupId, name) in names where groups[groupId] == nil { groups[groupId] = KnownGroup(groupId: groupId, name: name, modelKeys: []) }
        return groups.values.sorted { $0.groupId < $1.groupId }
    }
}
