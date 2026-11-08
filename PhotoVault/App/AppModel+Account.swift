import Foundation
import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultDrive
import PhotoVaultEngine
import PhotoVaultStore

/// Where Drive backups go after sign-in or a root change (FR-01 step 3, FR-08).
enum RootChoice: Equatable, Sendable {
    case createNew(name: String)
    case reuse(rootId: String, name: String)
}

/// Google account and Drive root management (FR-08).
extension AppModel {
    var googleConfigured: Bool { env?.googleConfigured ?? false }

    /// Opens the browser and waits for the loopback redirect (FR-02).
    func signInGoogle() async throws -> GoogleIdentity {
        guard let env else { throw EngineError.invalidState("no environment") }
        return try await env.auth.signIn()
    }

    func driveRoots() async throws -> [RemoteItem] {
        guard let env else { return [] }
        return try await DriveRootService(drive: env.drive).existingRoots()
    }

    /// Deletes the Keychain item, revokes the token and pauses Drive until the owner signs in again.
    func signOutGoogle() async {
        guard let env else { return }
        do {
            try await env.auth.signOut()
            let now = Date()
            try await env.store.write { db in
                if try DestinationRepository.fetch(db, id: .googleDrive) != nil {
                    try DestinationRepository.setStatus(db, id: .googleDrive, status: .paused(.signedOut), now: now)
                }
            }
            await refresh()
            showNotice("Đã đăng xuất Google.")
        } catch {
            showError(error)
        }
    }

    /// Signs in again. The same account simply resumes Drive; a different one needs a root choice.
    /// Returns the identity and whether the account differs from the stored one.
    func reauthenticate() async throws -> (identity: GoogleIdentity, accountChanged: Bool) {
        let identity = try await signInGoogle()
        let changed = driveRecord?.accountId.map { $0 != identity.sub } ?? false
        if !changed, let env, driveRecord != nil {
            let now = Date()
            try await env.store.write { db in
                try DestinationRepository.setStatus(db, id: .googleDrive, status: .active, now: now)
            }
            requestSync(.manual)
            await refresh()
        }
        return (identity, changed)
    }

    /// Points the Drive destination at a new or existing root, resetting what was learned about the old one.
    func applyDriveRoot(_ choice: RootChoice, identity: GoogleIdentity?) async throws {
        guard let env, var record = driveRecord else { throw EngineError.invalidState("no drive destination") }
        let service = DriveRootService(drive: env.drive)
        let now = Date()
        let rootId: String
        let rootName: String
        switch choice {
        case .createNew(let name):
            let root = try await service.createRoot(name: RootNameValidator.normalized(name), archiveTimeZone: archiveTimeZone)
            (rootId, rootName) = (root.remoteId, root.name)
        case .reuse(let id, let name):
            guard hardening != nil else { throw EngineError.invalidState("recovery unavailable") }
            (rootId, rootName) = (id, name)
        }
        record.config.driveRootId = rootId
        record.config.driveRootName = rootName
        if let identity {
            record.accountId = identity.sub
            record.accountEmail = identity.email
        }
        if record.status != .active {
            record.status = .active
            record.statusSince = now
        }
        let stored = record
        let reuse = { if case .reuse = choice { true } else { false } }()
        try await env.store.write { db in
            try DestinationRepository.save(db, stored)
            try DestinationRepository.resetState(db, id: .googleDrive)
            // A root created a moment ago is empty: there is nothing to recover from it.
            if !reuse { try DestinationRepository.setRecoveryRequired(db, id: .googleDrive, false) }
        }
        await env.drive.setRootId(rootId)
        await env.registry.add(env.drive)
        if reuse, let hardening { try await hardening.adoptExistingRoot(.googleDrive, rootId: rootId) }
        try await env.coordinator.destinationRulesChanged(.googleDrive)
        requestSync(.manual)
        await refresh()
        showNotice(reuse ? "Đang khôi phục trạng thái từ thư mục đã chọn." : "Đã tạo thư mục “\(rootName)” và đặt lại đích Drive.")
    }

    /// Renames the root on Drive; backups are not affected because files are addressed by ID.
    func renameDriveRoot(to name: String) async {
        guard let env, let rootId = driveRecord?.config.driveRootId else { return }
        let clean = RootNameValidator.normalized(name)
        if let issue = RootNameValidator.validate(clean) {
            showNotice(issue.message, isError: true)
            return
        }
        do {
            try await DriveRootService(drive: env.drive).rename(rootId: rootId, to: clean)
            try await env.store.write { db in
                guard var record = try DestinationRepository.fetch(db, id: .googleDrive) else { return }
                record.config.driveRootName = clean
                try DestinationRepository.save(db, record)
            }
            await refresh()
            showNotice("Đã đổi tên thư mục gốc thành “\(clean)”.")
        } catch {
            showError(error)
        }
    }
}
