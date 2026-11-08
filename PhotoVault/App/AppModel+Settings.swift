import Foundation
import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultEngine

/// Global settings (FR-05) and the archive timezone (FR-07).
extension AppModel {
    /// Validates the edited copy and saves it when valid. Content and organization changes make the
    /// engine recompute what goes where (FR-19); operating knobs only take effect.
    func commitSettings() async {
        settingsCommitsInFlight += 1
        defer { settingsCommitsInFlight -= 1 }
        let candidate = settings
        let issues = SettingsValidator.validate(candidate)
        settingsIssues = issues
        guard issues.isEmpty, candidate != persistedSettings, let env else { return }
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
            showNotice("Múi giờ lưu trữ: \(zone.identifier). Chỉ áp dụng cho ảnh chưa được xếp chỗ.")
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
                showNotice("Cho phép PhotoVault trong System Settings › General › Login Items.")
            }
        } catch {
            env?.log.log(.notice, category: "login-item", "could not change login item: \(type(of: error))")
            showNotice("Không đổi được mục mở khi đăng nhập (bản chưa ký có thể không hỗ trợ).", isError: true)
        }
    }
}
