import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

struct RecoveredFile: Sendable {
    var entry: RemoteFileEntry
    var assetKey: AssetKey
    var resType: ResourceType
    /// Identifier to record when the file's key differs from the asset's (8.1).
    var alias: String?
}

struct RecoveredShortcut: Sendable {
    var entry: RemoteShortcutEntry
    var assetKey: AssetKey
    var alias: String?
}

struct RecoveryMatches: Sendable {
    var files: [RecoveredFile] = []
    var unmatched: [RemoteFileEntry] = []
    var shortcuts: [RecoveredShortcut] = []
    var unmatchedShortcuts = 0
}

/// Spec 8.15 step 4: ties files found at a destination to assets of the database, in this order:
/// 1. `pvAssetId` / the sidecar's `assetKey` (an `h:` form through the hash index), or an alias;
/// 2. the cloud / local identifier written in the sidecar;
/// 3. the fingerprint: creation date (in the archive timezone) + original stem + pixel size or
///    duration. Files are downloaded only when several assets still fit: then the candidates are
///    exported, rate-limited, and compared by hash. What stays ambiguous is left untouched.
struct RecoveryMatcher: Sendable {
    let env: EngineEnvironment
    let record: DestinationRecord
    let timeZone: TimeZone

    private struct AssetInfo: Sendable {
        var key: AssetKey
        var sourceId: SourceID
        var localId: String
        var width: Int
        var height: Int
        var duration: Double
    }

    /// Fingerprint index: `<date text>|<stem>` and `<epoch>|<stem>` → assets.
    private struct Index: Sendable {
        var assets: [AssetKey: AssetInfo] = [:]
        var byText: [String: [AssetKey]] = [:]
        var byEpoch: [String: [AssetKey]] = [:]
    }

    private enum Outcome: Sendable {
        case matched(AssetKey, ResourceType, alias: String?)
        case ambiguous([AssetKey])
        case none
    }

    func match(_ inventory: RemoteInventory) async throws -> RecoveryMatches {
        let index = try await buildIndex()
        var matches = RecoveryMatches()
        var exportsLeft = env.tuning.recoveryExportBudget
        for start in stride(from: 0, to: inventory.files.count, by: 300) {
            try Task.checkCancellation()
            let chunk = Array(inventory.files[start..<min(start + 300, inventory.files.count)])
            let outcomes: [Outcome] = try await env.store.read { db in try chunk.map { try classify($0, index: index, db: db) } }
            for (entry, outcome) in zip(chunk, outcomes) {
                switch outcome {
                case .matched(let key, let kind, let alias):
                    matches.files.append(RecoveredFile(entry: entry, assetKey: key, resType: kind, alias: alias))
                case .ambiguous(let candidates):
                    if let found = try await disambiguate(entry, candidates: candidates, index: index, budget: &exportsLeft) {
                        matches.files.append(found)
                    } else {
                        matches.unmatched.append(entry)
                    }
                case .none:
                    matches.unmatched.append(entry)
                }
            }
        }
        try await dedupe(&matches)
        try await matchShortcuts(inventory.shortcuts, into: &matches)
        return matches
    }

    // MARK: Index

    private func buildIndex() async throws -> Index {
        let zone = timeZone
        return try await env.store.read { db in
            var index = Index()
            for row in try Row.fetchAll(db, sql: "SELECT asset_key, source_id, local_id, creation_date, pixel_width, pixel_height, duration FROM asset") {
                guard let key = AssetKey(rawValue: row["asset_key"]) else { continue }
                index.assets[key] = AssetInfo(key: key, sourceId: SourceID(rawValue: row["source_id"]) ?? .photos, localId: row["local_id"], width: row["pixel_width"], height: row["pixel_height"], duration: row["duration"])
                let descriptors = try ResourceRepository.fetchAll(db, key: key).map(\.descriptor)
                guard let primary = ResourcePlanner.primary(of: descriptors) ?? descriptors.first else { continue }
                let stem = NameStemBuilder.originalStem(of: primary.originalFilename).lowercased()
                let created: Date? = row["creation_date"]
                if let created {
                    index.byText["\(NameFingerprint.dateText(created, in: zone))|\(stem)", default: []].append(key)
                    index.byEpoch["\(Int64(created.timeIntervalSince1970.rounded(.down)))|\(stem)", default: []].append(key)
                } else {
                    index.byText["undated|\(stem)", default: []].append(key)
                }
            }
            return index
        }
    }

    // MARK: Classification (one read transaction per chunk)

    private func classify(_ entry: RemoteFileEntry, index: Index, db: Database) throws -> Outcome {
        if let (key, alias) = try Self.resolve(claimed: entry.claimedKey, localId: entry.localId, cloudId: entry.cloudId, db: db) {
            guard let kind = try resourceType(of: entry, key: key, db: db) else { return .none }
            return .matched(key, kind, alias: alias)
        }
        var fitting: [AssetKey] = []
        for key in fingerprintCandidates(entry, index: index) where try resourceType(of: entry, key: key, db: db) != nil {
            fitting.append(key)
        }
        switch fitting.count {
        case 0: return .none
        case 1:
            guard let kind = try resourceType(of: entry, key: fitting[0], db: db) else { return .none }
            return .matched(fitting[0], kind, alias: nil)
        default: return .ambiguous(fitting.sorted())
        }
    }

    /// Strategies 1 and 2. The alias is the identifier of the claimed key when it differs from the asset's key.
    static func resolve(claimed: String?, localId: String?, cloudId: String?, db: Database) throws -> (AssetKey, String?)? {
        var claimedKey: AssetKey?
        if let claimed {
            if claimed.hasPrefix("h:") {
                let found = try AssetRepository.fetch(db, hashPrefix: String(claimed.dropFirst(2)))
                if found.count == 1 { return (found[0].assetKey, nil) }
            } else if let key = AssetKey(rawValue: claimed) {
                claimedKey = key
                if try AssetRepository.fetch(db, key: key) != nil { return (key, nil) }
                let asset = key.isCloud
                    ? try AssetRepository.find(db, localId: nil, cloudId: key.identifier)
                    : try AssetRepository.find(db, localId: key.identifier, cloudId: nil)
                if let asset { return (asset.assetKey, key.identifier) }
            }
        }
        if localId != nil || cloudId != nil, let asset = try AssetRepository.find(db, localId: localId, cloudId: cloudId) {
            return (asset.assetKey, claimedKey.flatMap { $0 == asset.assetKey ? nil : $0.identifier })
        }
        return nil
    }

    /// Strategy 3 candidates, narrowed by pixel size / duration when the sidecar gave them.
    private func fingerprintCandidates(_ entry: RemoteFileEntry, index: Index) -> [AssetKey] {
        guard let name = entry.name else { return [] }
        var stems = [name.originalStem.lowercased()]
        if let stripped = NameFingerprint.withoutCollisionSuffix(name.originalStem) { stems.append(stripped.lowercased()) }
        var found = Set<AssetKey>()
        for stem in stems {
            found.formUnion(index.byText["\(name.dateText ?? "undated")|\(stem)"] ?? [])
            if let epoch = entry.epoch { found.formUnion(index.byEpoch["\(epoch)|\(stem)"] ?? []) }
        }
        return found.filter { key in
            guard let info = index.assets[key] else { return false }
            if let width = entry.pixelWidth, let height = entry.pixelHeight, info.width > 0, info.height > 0,
               width != info.width || height != info.height { return false }
            if let duration = entry.duration, abs(duration - info.duration) > 0.5 { return false }
            return true
        }.sorted()
    }

    /// The resource of `key` this file stands for; nil when the asset has no such resource.
    private func resourceType(of entry: RemoteFileEntry, key: AssetKey, db: Database) throws -> ResourceType? {
        let resources = try ResourceRepository.fetchAll(db, key: key)
        if let known = entry.resType {
            return known.isSidecar || resources.contains(where: { $0.type == known }) ? known : nil
        }
        guard let name = entry.name else { return nil }
        let ext = name.ext.lowercased()
        if ext == "json" { return .sidecarJson }
        if ext == "xmp" { return .sidecarXmp }
        let builder = env.nameBuilder(timeZone)
        let wanted: ResourceKind = name.isEdited ? .edited : .original
        return resources.filter { $0.kind == wanted }.sorted { $0.type < $1.type }.first { resource in
            (builder.fileName(stem: "x", resource: resource) as NSString).pathExtension.lowercased() == ext
        }?.type
    }

    // MARK: Look-alike candidates

    private func disambiguate(_ entry: RemoteFileEntry, candidates: [AssetKey], index: Index, budget: inout Int) async throws -> RecoveredFile? {
        guard let remote = try await remoteHash(of: entry) else { return nil }
        var hits: [RecoveredFile] = []
        for key in candidates.prefix(5) {
            guard budget > 0, let info = index.assets[key] else { break }
            let resolved: ResourceType? = try await env.store.read { db in try resourceType(of: entry, key: key, db: db) }
            guard let resolved, !resolved.isSidecar else { continue }
            let filename = try await env.store.read { db in try ResourceRepository.fetch(db, key: key, type: resolved)?.originalFilename } ?? ""
            budget -= 1
            try await env.tuning.sleep(env.tuning.recoveryExportInterval)
            let directory = env.stagingDirectory.appendingPathComponent("recovery-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                guard let content = await env.sources.content(for: info.sourceId) else { throw SourceError.unavailable }
                let locator = ResourceLocator(sourceId: info.sourceId, localId: info.localId, type: resolved, originalFilename: filename)
                let exported = try await content.exportResource(locator, to: directory.appendingPathComponent("candidate"), control: ExportControl())
                if (remote.kind == .md5 ? exported.md5 : exported.sha256) == remote.value {
                    hits.append(RecoveredFile(entry: entry, assetKey: key, resType: resolved, alias: nil))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                env.log.log(.notice, category: "recovery", "candidate export failed type=\(type(of: error))")
            }
        }
        // Two assets with identical bytes cannot be told apart: the file is left alone.
        return hits.count == 1 ? hits[0] : nil
    }

    private func remoteHash(of entry: RemoteFileEntry) async throws -> (kind: ContentHashKind, value: String)? {
        if let md5 = entry.item.md5 { return (.md5, md5) }
        if let sha = entry.item.sha256 ?? entry.uploadedHash { return (.sha256, sha) }
        guard let reader = env.localContent,
              let sha = try await reader.sha256(destination: record.id, path: entry.item.relativePath ?? entry.item.remoteId)
        else { return nil }
        return (.sha256, sha)
    }

    // MARK: Cleanup

    /// One file per (asset, resource): the one the database already points at, otherwise the first.
    private func dedupe(_ matches: inout RecoveryMatches) async throws {
        let id = record.id
        let existing: [String: String] = try await env.store.read { db in
            var map: [String: String] = [:]
            let rows = try Row.fetchAll(
                db, sql: "SELECT asset_key, res_type, remote_id FROM upload_job WHERE destination_id = ? AND remote_id IS NOT NULL",
                arguments: [id.rawValue])
            for row in rows { map["\(row["asset_key"] as String)|\(row["res_type"] as Int)"] = row["remote_id"] }
            return map
        }
        var chosen: [String: RecoveredFile] = [:]
        var rejected: [RemoteFileEntry] = []
        for file in matches.files {
            let slot = "\(file.assetKey.rawValue)|\(file.resType.rawValue)"
            guard let current = chosen[slot] else {
                chosen[slot] = file
                continue
            }
            if file.entry.item.remoteId == existing[slot], current.entry.item.remoteId != existing[slot] {
                rejected.append(current.entry)
                chosen[slot] = file
            } else {
                rejected.append(file.entry)
            }
        }
        matches.files = chosen.values.sorted { $0.entry.item.remoteId < $1.entry.item.remoteId }
        matches.unmatched.append(contentsOf: rejected)
    }

    private func matchShortcuts(_ shortcuts: [RemoteShortcutEntry], into matches: inout RecoveryMatches) async throws {
        for start in stride(from: 0, to: shortcuts.count, by: 300) {
            let chunk = Array(shortcuts[start..<min(start + 300, shortcuts.count)])
            let resolved: [(RemoteShortcutEntry, AssetKey, String?)?] = try await env.store.read { db in
                try chunk.map { entry in
                    try Self.resolve(claimed: entry.claimedKey, localId: nil, cloudId: nil, db: db).map { (entry, $0.0, $0.1) }
                }
            }
            for item in resolved {
                if let (entry, key, alias) = item {
                    matches.shortcuts.append(RecoveredShortcut(entry: entry, assetKey: key, alias: alias))
                } else {
                    matches.unmatchedShortcuts += 1
                }
            }
        }
    }
}
