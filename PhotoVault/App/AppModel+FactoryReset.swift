import AppKit
import PhotoVaultCore
import PhotoVaultEngine

extension AppModel {
    /// Factory Reset (start over): stops syncing, signs out of Google, marks the data folder for
    /// wiping and relaunches; the new process empties the folder before anything opens it and shows
    /// onboarding. Destinations are not touched.
    func factoryReset() async {
        guard let env, !factoryResetInProgress else { return }
        factoryResetInProgress = true
        showNotice(tr(vi: "Đang đặt lại PhotoVault…", en: "Resetting PhotoVault…"))
        let wasPaused = isPausedAll
        await env.coordinator.pauseAll()
        do {
            try await env.auth.signOut()
            try FactoryReset.request(env.layout)
        } catch {
            env.log.log(.error, category: "reset", "factory reset could not start: \(type(of: error))")
            if !wasPaused { await env.coordinator.resumeAll() }
            factoryResetInProgress = false
            showError(error)
            return
        }
        env.log.log(.notice, category: "reset", "factory reset requested; relaunching")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        // A development build needs its --dev-container argument again.
        configuration.arguments = Array(CommandLine.arguments.dropFirst())
        do {
            _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        } catch {
            // The marker is written: the reset finishes whenever PhotoVault next starts.
            env.log.log(.error, category: "reset", "relaunch failed: \(type(of: error))")
            showNotice(tr(
                vi: "Đã đăng xuất và đánh dấu đặt lại, nhưng chưa tự mở lại được PhotoVault. Hãy thoát rồi mở lại: việc đặt lại sẽ hoàn tất ở lần mở tiếp theo.",
                en: "Signed out and marked for reset, but PhotoVault could not reopen itself. Quit and open it again: the reset finishes on the next launch."))
            return
        }
        // The new process waits for this one's lock, then wipes.
        NSApp.terminate(nil)
    }
}
