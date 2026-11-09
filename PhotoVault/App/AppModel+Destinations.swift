import Foundation
import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultEngine
import PhotoVaultLocal
import PhotoVaultStore

/// A folder the owner picked that is not yet a destination (FR-70, FR-71, FR-74).
struct PendingLocalDestination: Identifiable, Equatable {
    let id = UUID()
    var destinationId: DestinationID
    var url: URL
    var bookmark: Data
    var name: String
    /// `.photovault/destination.json` found in the folder: it already was a destination (FR-74).
    var existingMarker: DestinationMarker?
    var testPassed = false
    var freeBytes: Int64?
    var scope: ScopeMode = .full
    var rules = DestinationRules.everything

    var isReuse: Bool { existingMarker != nil }
}

extension AppModel {
    // MARK: Adding

    /// NSOpenPanel, then a look for `destination.json`. A folder that already belongs to another
    /// destination row is refused.
    func pickLocalFolder() async -> PendingLocalDestination? {
        guard let env else { return nil }
        guard let pick = FolderPicker.chooseFolder(message: tr(vi: "Chọn thư mục trên NAS hoặc ổ ngoài đã mount trong Finder.", en: "Choose a folder on a NAS or external drive that is mounted in Finder.")) else { return nil }
        let existing = destinations.compactMap { record in
            record.kind == .localFolder ? record.config.displayPath.map { (name: record.displayName, path: $0) } : nil
        }
        if let hit = DestinationNesting.conflict(candidate: pick.url.resolvingSymlinksInPath().path, existing: existing)
            ?? DestinationNesting.conflict(candidate: pick.url.path, existing: existing) {
            showNotice(DestinationNesting.message(name: hit.name, relation: hit.relation), isError: true)
            return nil
        }
        let probe = DestinationBuilder.local(id: .local(), bookmark: pick.bookmark, store: env.store, disk: env.disk, log: env.log)
        do {
            let marker = try await probe.readMarker()
            if let marker, destinations.contains(where: { $0.id == marker.id }) {
                showNotice(tr(vi: "Thư mục này đã là một đích của PhotoVault.", en: "This folder is already a PhotoVault destination."), isError: true)
                return nil
            }
            return PendingLocalDestination(
                destinationId: marker?.id ?? .local(), url: pick.url, bookmark: pick.bookmark,
                name: pick.volumeName ?? pick.url.lastPathComponent, existingMarker: marker)
        } catch {
            showError(error)
            return nil
        }
    }

    func localDestination(for pending: PendingLocalDestination) -> LocalFolderDestination? {
        guard let env else { return nil }
        return DestinationBuilder.local(id: pending.destinationId, bookmark: pending.bookmark, store: env.store, disk: env.disk, log: env.log)
    }

    /// Writes, reads back and deletes `.photovault-test` (FR-70).
    func testConnection(_ pending: PendingLocalDestination) async -> PendingLocalDestination {
        var result = pending
        guard let destination = localDestination(for: pending) else { return result }
        do {
            try await destination.testConnection()
            result.testPassed = true
            result.freeBytes = try? await destination.quota()?.availableBytes
        } catch {
            result.testPassed = false
            showError(error)
        }
        return result
    }

    /// Stores the destination and registers it. The caller decides what the engine does next:
    /// onboarding takes the baseline, Settings calls `addLocalDestination`.
    @discardableResult
    func commit(_ pending: PendingLocalDestination) async throws -> DestinationRecord {
        guard let env, let destination = localDestination(for: pending) else { throw EngineError.invalidState("no environment") }
        let now = Date()
        let marker = DestinationMarker(id: pending.destinationId, createdAt: now, archiveTimezone: archiveTimeZone.identifier)
        let written = try await destination.writeMarker(marker)
        let record = DestinationRecord(
            id: pending.destinationId, displayName: pending.name.trimmingCharacters(in: .whitespacesAndNewlines),
            statusSince: now, scope: pending.scope, rules: pending.rules,
            config: DestinationConfig(bookmark: pending.bookmark, displayPath: pending.url.path, localMarkerId: written.id.rawValue),
            recoveryRequired: pending.isReuse, createdAt: now)
        let stored = try await env.store.write { db in try DestinationRepository.add(db, record, now: now) }
        await env.registry.add(destination)
        await refresh()
        return stored
    }

    /// Settings › Đích › +: commit, queue from the database (FR-71), recover state when the folder is reused (FR-74).
    func addLocalDestination(_ pending: PendingLocalDestination) async -> Bool {
        guard let env else { return false }
        if pending.isReuse, hardening == nil {
            showNotice(tr(vi: "Dùng lại thư mục cũ cần chức năng khôi phục, chưa khả dụng trong bản build này.", en: "Reusing an old folder needs recovery, which is not available in this build."), isError: true)
            return false
        }
        do {
            let record = try await commit(pending)
            try await env.coordinator.destinationAdded(record.id)
            if pending.isReuse, let hardening {
                let report = try await hardening.startRecovery(record.id)
                showNotice(tr(vi: "Đã khôi phục: ghép \(VietnameseFormat.integer(report.matchedFiles)) file từ thư mục.", en: "Recovered: matched \(L10n.plural(report.matchedFiles, one: "\(VietnameseFormat.integer(report.matchedFiles)) file", other: "\(VietnameseFormat.integer(report.matchedFiles)) files")) from the folder."))
            } else {
                showNotice(tr(vi: "Đã thêm “\(record.displayName)”.", en: "Added “\(record.displayName)”."))
            }
            requestSync(.manual)
            await refresh()
            return true
        } catch {
            showError(error)
            return false
        }
    }

    // MARK: Editing

    func updateDestination(_ id: DestinationID, name: String? = nil, rules: DestinationRules, scope: ScopeMode) async {
        guard let env else { return }
        do {
            try await env.store.write { db in
                guard var record = try DestinationRepository.fetch(db, id: id) else { throw StoreError.notFound("destination") }
                if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { record.displayName = name.trimmingCharacters(in: .whitespaces) }
                record.rules = rules
                record.scope = scope
                try DestinationRepository.save(db, record)
            }
            try await env.coordinator.destinationRulesChanged(id)
            requestSync(.manual)
            await refresh()
            showNotice(tr(vi: "Đã áp dụng cho đích.", en: "Applied to the destination."))
        } catch {
            showError(error)
        }
    }

    /// FR-71: forgets the destination in the database; nothing at the destination is touched.
    func removeDestination(_ record: DestinationRecord) async {
        guard let env, record.kind == .localFolder else { return }
        do {
            // Stop its transfers first, so none finishes into a row that is already gone.
            await env.coordinator.destinationRemoved(record.id)
            try await env.store.write { db in try DestinationRepository.remove(db, id: record.id) }
            await refresh()
            showNotice(tr(vi: "Đã xoá đích khỏi PhotoVault; file ở đích giữ nguyên.", en: "Removed the destination from PhotoVault; files at the destination are untouched."))
        } catch {
            showError(error)
        }
    }

    /// Test connection for an existing destination (FR-70).
    func testConnection(_ record: DestinationRecord) async {
        guard let env else { return }
        if record.kind == .googleDrive {
            let status = await env.drive.checkAvailability()
            let presentation = StatusText.presentation(for: status)
            showNotice("Google Drive: \(presentation.label).", isError: !status.isActive)
            return
        }
        guard let destination = await env.registry.destination(for: record.id) as? LocalFolderDestination else {
            showNotice(tr(vi: "Đích chưa sẵn sàng. Hãy chọn lại thư mục.", en: "The destination is not ready. Choose the folder again."), isError: true)
            return
        }
        do {
            try await destination.testConnection()
            showNotice(tr(vi: "Kết nối tốt: ghi, đọc và xoá .photovault-test thành công.", en: "Connection is good: wrote, read and deleted .photovault-test."))
        } catch {
            showError(error)
        }
    }

    /// FR-75: after a broken bookmark, pick the folder again. It must be the same destination.
    func repickFolder(for record: DestinationRecord) async {
        guard let env, let pick = FolderPicker.chooseFolder(message: tr(vi: "Chọn lại thư mục của “\(record.displayName)”.", en: "Choose the folder of “\(record.displayName)” again.")) else { return }
        let probe = DestinationBuilder.local(id: record.id, bookmark: pick.bookmark, store: env.store, disk: env.disk, log: env.log)
        do {
            guard let marker = try await probe.readMarker(), marker.id == record.id else {
                showNotice(tr(vi: "Thư mục này không phải là thư mục của đích “\(record.displayName)”.", en: "This is not the folder of the destination “\(record.displayName)”."), isError: true)
                return
            }
            let updated = pick
            try await env.store.write { db in
                guard var stored = try DestinationRepository.fetch(db, id: record.id) else { return }
                stored.config.bookmark = updated.bookmark
                stored.config.displayPath = updated.url.path
                try DestinationRepository.save(db, stored)
            }
            await env.registry.add(probe)
            requestSync(.manual)
            await refresh()
            showNotice(tr(vi: "Đã chọn lại thư mục.", en: "Folder chosen again."))
        } catch {
            showError(error)
        }
    }

    /// Free space of a destination (Drive quota or volume).
    func freeSpace(of record: DestinationRecord) async -> Int64? {
        guard let env, let destination = await env.registry.destination(for: record.id) else { return nil }
        return try? await destination.quota()?.availableBytes
    }
}
