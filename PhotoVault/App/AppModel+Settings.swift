import Foundation
import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultEngine

/// Global settings (FR-05) and the archive timezone (FR-07).
extension AppModel {
    /// Validates the edited copy and saves every valid change; fields with an issue keep their saved
    /// value until fixed, and the issues are shown on every tab. Content and organization changes make
    /// the engine recompute what goes where (FR-19); operating knobs only take effect.
    func commitSettings() async {
        settingsCommitsInFlight += 1
        defer { settingsCommitsInFlight -= 1 }
        settingsIssues = SettingsValidator.validate(settings)
        let candidate = SettingsValidator.savable(settings, persisted: persistedSettings)
        guard candidate != persistedSettings, let env else { return }
        let old = persistedSettings
        do {
            try await env.settings.update { $0 = candidate }
            persistedSettings = candidate
            if SettingsValidator.needsEngineRecompute(from: old, to: candidate) {
                try await env.coordinator.settingsChanged()
                requestSync(.manual)
            }
            if old.launchAtLogin != candidate.launchAtLogin { await applyLoginItem(candidate.launchAtLogin) }
        } catch {
            settings = persistedSettings
            showError(error)
        }
    }

    func scheduleCommit() {
        Task { await commitSettings() }
    }

    func setArchiveTimeZone(_ zone: TimeZone) async {
        guard let env, zone.identifier != archiveTimeZone.identifier else { return }
        do {
            try await env.settings.setArchiveTimeZone(zone)
            archiveTimeZone = zone
            showNotice(tr(
                vi: "Múi giờ lưu trữ: \(zone.identifier). Chỉ áp dụng cho ảnh chưa được xếp chỗ.",
                en: "Archive time zone: \(zone.identifier). Applies only to photos not yet placed."))
        } catch {
            showError(error)
        }
    }

    // MARK: Login item (FR-62)

    /// At launch: bring the login item in line with the saved choice.
    func reconcileLoginItem() async {
        guard persistedSettings.launchAtLogin != LoginItemService.isEnabled else { return }
        await applyLoginItem(persistedSettings.launchAtLogin)
    }

    func applyLoginItem(_ enabled: Bool) async {
        do {
            try LoginItemService.set(enabled)
            if enabled, LoginItemService.needsApproval {
                showNotice(tr(
                    vi: "Cho phép PhotoVault trong System Settings › General › Login Items.",
                    en: "Allow PhotoVault in System Settings › General › Login Items."))
            }
        } catch {
            env?.log.log(.notice, category: "login-item", "could not change login item: \(type(of: error))")
            showNotice(
                tr(vi: "Không đổi được mục mở khi đăng nhập (bản chưa ký có thể không hỗ trợ).",
                   en: "Could not change the login item (an unsigned build may not support it)."),
                isError: true)
        }
    }
}
