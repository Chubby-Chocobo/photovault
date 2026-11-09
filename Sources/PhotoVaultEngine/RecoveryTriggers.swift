import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// The ways a destination becomes `recovery_required` (FR-51) besides a database restore, which
/// the Store marks itself:
/// - an empty database with data at the destination (found on the first cycle, before any job exists);
/// - a reused Drive root (FR-01 step 3) or a re-added NAS folder (FR-74);
/// - a changed root or account (FR-08);
/// - the owner asking.
struct RecoveryTriggers: Sendable {
    static let probeKey = "recovery_probe:"

    let env: EngineEnvironment
    let forget: @Sendable (DestinationID) async -> Void

    // MARK: Detection

    /// Looks once at every destination that never held a confirmed file of this database: when it
    /// contains backup files, recovery is required before anything is uploaded. A destination
    /// that cannot be reached is looked at again next cycle.
    func detectDataAtDestinations() async throws {
        let records: [DestinationRecord] = try await env.store.read { db in
            try DestinationRepository.fetchAll(db).filter { record in
                guard !record.recoveryRequired, record.status != .paused(.userPaused) else { return false }
                let probed = try KeyValueRepository.int(db, Self.probeKey + record.id.rawValue) == 1
                return try !probed && JobRepository.count(db, destinationId: record.id, state: .done) == 0
            }
        }
        for record in records {
            try Task.checkCancellation()
            guard let destination = await env.destinations.destination(for: record.id),
                  await destination.checkAvailability() == .active else { continue }
            let found: Bool
            do {
                found = try await hasBackupFiles(destination, rootId: record.config.driveRootId)
            } catch let error as DestinationError {
                env.log.log(.notice, category: "recovery", "probe failed destination=\(record.id) error=\(error)")
                continue
            }
            let id = record.id
            let now = env.clock.now
            try await env.store.write { db in
                try KeyValueRepository.set(db, Self.probeKey + id.rawValue, 1)
                guard found else { return }
                try DestinationRepository.setRecoveryRequired(db, id: id, true)
                try ActivityRepository.record(db, ActivityEvent(
                    at: now, kind: .notice, destinationId: id, message: "Đích đã có dữ liệu sao lưu; sẽ khôi phục trước khi upload"))
            }
            if found { env.log.log(.notice, category: "recovery", "destination=\(id) holds backup files: recovery required") }
        }
    }

    /// Backup files, not folders: the root itself and the folders made for the first uploads carry
    /// the app's schema too. On Drive the listing covers the whole account, so only files under this
    /// destination's root count; another PhotoVault root in the same account is not this one's data.
    private func hasBackupFiles(_ destination: any Destination, rootId: String?) async throws -> Bool {
        guard destination.capabilities.supportsAppProperties else {
            for try await item in destination.list(under: nil) where !item.trashed {
                if item.kind == .file, NameFingerprint.parse(item.name) != nil { return true }
            }
            return false
        }
        guard let rootId else { return false }
        var parents: [String: String] = [:]
        var files: [RemoteItem] = []
        for try await item in destination.list(under: nil) where !item.trashed
            && item.appProperties[AppPropertyKey.schema] == AppPropertyCodec.schemaVersion {
            if let parent = item.parentIds.first { parents[item.remoteId] = parent }
            if item.kind == .file { files.append(item) }
        }
        return files.contains { file in
            var current = file.parentIds.first
            var hops = 0
            while let id = current, hops < 64 {
                if id == rootId { return true }
                current = parents[id]
                hops += 1
            }
            return false
        }
    }

    // MARK: Commands

    /// FR-01 step 3 / FR-74: the owner reuses a Drive root carrying `pvRoot=1`, or re-adds a NAS
    /// folder with `destination.json` (`rootId` is then ignored).
    func adoptExistingRoot(_ id: DestinationID, rootId: String) async throws {
        try await reset(id, root: rootId, name: nil, account: nil, expectsContent: true)
    }

    /// FR-08: the Drive root or account changed. The old location's state is dropped; the new
    /// root is recovered when it has content, otherwise everything is queued per scope.
    func changeDriveRoot(_ id: DestinationID, rootId: String, rootName: String, account: DriveAccount?, rootHasContent: Bool) async throws {
        try await reset(id, root: rootId, name: rootName, account: account, expectsContent: rootHasContent)
    }

    /// FR-08 with a new account: `checker` belongs to the staged account, never to the registry.
    /// Nothing is written unless the root is fine and `commit` succeeds.
    func changeDriveAccount(
        _ id: DestinationID, rootId: String, rootName: String, account: DriveAccount, rootHasContent: Bool,
        checker: any RootManaging, commit: @Sendable () async throws -> Void
    ) async throws {
        try Self.requireOk(try await checker.checkRoot(remoteId: rootId))
        try await commit()
        try await apply(id, root: rootId, name: rootName, account: account, expectsContent: rootHasContent)
    }

    @discardableResult
    private static func requireOk(_ check: RootCheck) throws -> RemoteItem {
        switch check {
        case .ok(let item): return item
        case .missing: throw RootProblemError.stillMissing
        case .trashed: throw RootProblemError.stillTrashed
        }
    }

    private func reset(_ id: DestinationID, root: String, name: String?, account: DriveAccount?, expectsContent: Bool) async throws {
        guard let destination = await env.destinations.destination(for: id) else { throw EngineError.invalidState("unknown destination") }
        var rootName = name
        if destination.capabilities.supportsAppProperties {
            guard let managing = destination as? any RootManaging else { throw RootProblemError.unsupported }
            let item = try Self.requireOk(try await managing.checkRoot(remoteId: root))
            rootName = rootName ?? item.name
        }
        try await apply(id, root: root, name: rootName, account: account, expectsContent: expectsContent)
    }

    private func apply(_ id: DestinationID, root: String, name rootName: String?, account: DriveAccount?, expectsContent: Bool) async throws {
        let now = env.clock.now
        let rootText = rootName
        try await env.store.write { db in
            guard var record = try DestinationRepository.fetch(db, id: id) else { throw StoreError.notFound("destination \(id)") }
            if record.kind == .googleDrive {
                record.config.driveRootId = root
                record.config.driveRootName = rootText ?? record.config.driveRootName
            }
            if let account {
                record.accountId = account.id
                record.accountEmail = account.email
            }
            try DestinationRepository.save(db, record)
            try Self.dropDestinationKnowledge(db, id: id)
            try KeyValueRepository.set(db, Self.probeKey + id.rawValue, 1)
            if expectsContent {
                try KeyValueRepository.set(db, RecoveryService.expectsKey + id.rawValue, 1)
                try DestinationRepository.setStatus(db, id: id, status: .paused(.recovering), now: now)
            } else {
                // A new, empty root: nothing to recover.
                try DestinationRepository.setRecoveryRequired(db, id: id, false)
                try DestinationRepository.setStatus(db, id: id, status: .active, now: now)
                try KeyValueRepository.set(db, RecoveryService.enqueueKey + id.rawValue, 1)
            }
        }
        await forget(id)
    }

    /// Everything the database learned about the old location (jobs, folders, moves, shortcuts and
    /// the notes kept per destination).
    static func dropDestinationKnowledge(_ db: Database, id: DestinationID) throws {
        try DestinationRepository.resetState(db, id: id)
        let exact = ["views_disabled:", RecoveryService.decisionKey, RecoveryService.expectsKey, RecoveryService.enqueueKey,
                     RecoveryVerifier.cursorKey, RecoveryVerifier.limitKey, IntegrityChecker.lastRunKey,
                     IntegrityChecker.resultMissingKey, IntegrityChecker.resultMismatchKey, IntegrityChecker.resultAtKey,
                     IntegrityChecker.mismatchDismissedKey]
        for prefix in exact { try KeyValueRepository.set(db, prefix + id.rawValue, nil) }
        for prefix in ["desc:", "viewhold:"] {
            let head = prefix + id.rawValue + ":"
            try db.execute(sql: "DELETE FROM kv WHERE substr(key, 1, ?) = ?", arguments: [head.count, head])
        }
    }
}

/// Account details stored with a Drive destination (FR-08).
public struct DriveAccount: Sendable, Equatable {
    public var id: String
    public var email: String?

    public init(id: String, email: String?) {
        self.id = id
        self.email = email
    }
}
