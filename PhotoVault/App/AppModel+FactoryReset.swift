import AppKit
import PhotoVaultCore
import PhotoVaultEngine

extension AppModel {
    /// Factory Reset (start over): stops syncing, signs out of Google, marks the data folder for
    /// wiping and relaunches; the new process empties the folder before anything opens it and shows
    /// onboarding. Destinations are not touched.
    func factoryReset() async {
        guard let env else { return }
        await env.coordinator.pauseAll()
        do {
            try await env.auth.signOut()
            try FactoryReset.request(env.layout)
        } catch {
            env.log.log(.error, category: "reset", "factory reset could not start: \(type(of: error))")
            await env.coordinator.resumeAll()
            showError(error)
            return
        }
        env.log.log(.notice, category: "reset", "factory reset requested; relaunching")
        env.fileLog.close()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in }
        // The new process waits for this one's lock, then wipes.
        try? await Task.sleep(for: .milliseconds(300))
        NSApp.terminate(nil)
    }
}
