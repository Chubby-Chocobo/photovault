import SwiftUI
import PhotoVaultCore

@main
struct PhotoVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window(tr(vi: "Chào mừng đến PhotoVault", en: "Welcome to PhotoVault"), id: WindowID.onboarding) {
            OnboardingView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window(tr(vi: "Hoạt động gần đây", en: "Recent activity"), id: WindowID.activity) {
            ActivityView()
                .environment(model)
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)

        Window(tr(vi: "Nhật ký", en: "Log"), id: WindowID.log) {
            LogView()
                .environment(model)
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

enum WindowID {
    static let onboarding = "onboarding"
    static let activity = "activity"
    static let log = "log"
}
