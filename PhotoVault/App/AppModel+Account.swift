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

/// A sign-in in progress during "Đổi tài khoản". `staged` is nil when it turned out to be the same account.
struct AccountChange: Sendable {
    var staged: StagedAccount?
    var identity: GoogleIdentity
    /// Drive was active before the change and is resumed if the owner cancels.
    var resumeDrive: Bool
    /// Marks the change as open until it is applied or cancelled, so Drive resumes at most once.
    var token = UUID()
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

    /// FR-08 step 1: signs in with the browser but keeps the new account staged (in memory only).
    /// Drive is paused meanwhile, so nothing is uploaded with the wrong account's token. The same
    /// account is committed at once and Drive resumes. If the calling task is cancelled while the browser
    /// is open, a stage that still arrives is discarded and Drive resumes.
    func beginAccountChange() async throws -> AccountChange {
        guard let env else { throw EngineError.invalidState("no environment") }
        let wasActive = driveRecord?.status == .active
        if driveRecord != nil, wasActive { try await env.coordinator.pause(destination: .googleDrive) }
        let staged: StagedAccount
        do {
            staged = try await env.auth.beginAccountChange()
        } catch {
            if wasActive { try? await env.coordinator.resume(destination: .googleDrive) }
            throw error
        }
        if Task.isCancelled {
            await env.auth.discardAccountChange(staged)
            if wasActive { try? await env.coordinator.resume(destination: .googleDrive) }
            throw CancellationError()
        }
        let changed = driveRecord?.accountId.map { $0 != staged.identity.sub } ?? false
        guard changed else {
            do {
                try await env.auth.commitAccountChange(staged)
                if driveRecord != nil { try await resumeDriveAfterSignIn(env, undoOurPause: wasActive) }
            } catch {
                if wasActive { try? await env.coordinator.resume(destination: .googleDrive) }
                throw error
            }
            return AccountChange(staged: nil, identity: staged.identity, resumeDrive: false)
        }
        let change = AccountChange(staged: staged, identity: staged.identity, resumeDrive: wasActive)
        openAccountChanges.insert(change.token)
        return change
    }

    /// PhotoVault roots in the staged account, listed before that account goes live.
    func driveRoots(for change: AccountChange) async throws -> [RemoteItem] {
        guard let env, let staged = change.staged else { return try await driveRoots() }
        return try await DriveRootService(drive: stagedDrive(env, staged)).existingRoots()
    }

    /// "Huỷ": the old account and its state stay exactly as they were. Does nothing for a change that
    /// was already applied, cancelled or discarded after a failure.
    func cancelAccountChange(_ change: AccountChange) async {
        guard let env, let staged = change.staged, openAccountChanges.remove(change.token) != nil else { return }
        await env.auth.discardAccountChange(staged)
        if change.resumeDrive { try? await env.coordinator.resume(destination: .googleDrive) }
    }

    /// FR-08 confirm. The staged account stays out of the Keychain until the engine reset has succeeded:
    /// the reset checks the new root through a destination built on the staged account. On any failure
    /// the stage is discarded, the old account stays live and Drive returns to what it was.
    func applyAccountChange(_ change: AccountChange, choice: RootChoice) async throws {
        guard let env, let staged = change.staged else { return try await applyDriveRoot(choice, identity: nil) }
        guard openAccountChanges.contains(change.token) else {
            throw EngineError.invalidState("account change no longer pending")
        }
        let stagedDrive = stagedDrive(env, staged)
        let account = DriveAccount(id: staged.identity.sub, email: staged.identity.email)
        do {
            let root = try await resolveRoot(choice, using: DriveRootService(drive: stagedDrive))
            await stagedDrive.setRootId(root.id)
            await env.registry.add(stagedDrive)
            do {
                try await env.coordinator.changeDriveRoot(
                    .googleDrive, rootId: root.id, rootName: root.name, account: account, rootHasContent: root.reused)
            } catch {
                await env.registry.add(env.drive)
                throw error
            }
            do {
                try await env.auth.commitAccountChange(staged)
            } catch {
                // The database now describes the new account but the Keychain still holds the old one.
                await env.drive.setRootId(root.id)
                await env.registry.add(env.drive)
                await markDriveSignedOut(env)
                throw error
            }
            openAccountChanges.remove(change.token)
            await env.drive.setRootId(root.id)
            await env.registry.add(env.drive)
            requestSync(.manual)
            await refresh()
            showNotice(root.reused ? "Đang khôi phục trạng thái từ thư mục đã chọn." : "Đã tạo thư mục “\(root.name)” và đặt lại đích Drive.")
        } catch {
            await cancelAccountChange(change)
            await refresh()
            throw error
        }
    }

    private func markDriveSignedOut(_ env: AppEnvironment) async {
        let now = Date()
        try? await env.store.write { db in
            if try DestinationRepository.fetch(db, id: .googleDrive) != nil {
                try DestinationRepository.setStatus(db, id: .googleDrive, status: .paused(.signedOut), now: now)
            }
        }
    }

    /// Same account, another root (FR-08).
    func applyDriveRoot(_ choice: RootChoice, identity: GoogleIdentity?) async throws {
        guard let env, driveRecord != nil else { throw EngineError.invalidState("no drive destination") }
        let root = try await resolveRoot(choice, using: DriveRootService(drive: env.drive))
        try await switchDriveRoot(env, root: root, account: identity.map { DriveAccount(id: $0.sub, email: $0.email) })
    }

    private struct ResolvedRoot {
        var id: String
        var name: String
        var reused: Bool
    }

    private func resolveRoot(_ choice: RootChoice, using service: DriveRootService) async throws -> ResolvedRoot {
        switch choice {
        case .createNew(let name):
            let root = try await service.createRoot(name: RootNameValidator.normalized(name), archiveTimeZone: archiveTimeZone)
            return ResolvedRoot(id: root.remoteId, name: root.name, reused: false)
        case .reuse(let id, let name):
            guard hardening != nil else { throw EngineError.invalidState("recovery unavailable") }
            return ResolvedRoot(id: id, name: name, reused: true)
        }
    }

    /// The engine drops what it knew about the old root in its exclusive lane, so no upload of the
    /// running cycle can race the reset.
    private func switchDriveRoot(_ env: AppEnvironment, root: ResolvedRoot, account: DriveAccount?) async throws {
        try await env.coordinator.changeDriveRoot(
            .googleDrive, rootId: root.id, rootName: root.name, account: account, rootHasContent: root.reused)
        await env.drive.setRootId(root.id)
        await env.registry.add(env.drive)
        requestSync(.manual)
        await refresh()
        showNotice(root.reused ? "Đang khôi phục trạng thái từ thư mục đã chọn." : "Đã tạo thư mục “\(root.name)” và đặt lại đích Drive.")
    }

    /// Clears sign-in states; a user pause is lifted only when this sign-in set it.
    private func resumeDriveAfterSignIn(_ env: AppEnvironment, undoOurPause: Bool) async throws {
        let now = Date()
        let reasons: [StatusReason] = undoOurPause ? [.signedOut, .reauthRequired, .userPaused] : [.signedOut, .reauthRequired]
        try await env.store.write { db in
            guard let record = try DestinationRepository.fetch(db, id: .googleDrive) else { return }
            if let reason = record.status.reason, reasons.contains(reason) {
                try DestinationRepository.setStatus(db, id: .googleDrive, status: .active, now: now)
            }
        }
        requestSync(.manual)
        await refresh()
    }

    private func stagedDrive(_ env: AppEnvironment, _ staged: StagedAccount) -> GoogleDriveDestination {
        GoogleDriveDestination(transport: env.transport, auth: staged, writeLimiter: nil, log: env.log)
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
