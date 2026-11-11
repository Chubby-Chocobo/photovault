import SwiftUI

/// The menu bar icon. It is also the one view that always exists, so it owns the environment
/// actions that open windows on behalf of the model.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .accessibilityLabel("PhotoVault")
            .help(model.transferLine ?? "PhotoVault")
            .onChange(of: model.windowRequest, initial: true) { _, request in
                guard let request else { return }
                model.windowRequest = nil
                switch request {
                case .onboarding: openWindow(id: WindowID.onboarding)
                case .activity: openWindow(id: WindowID.activity)
                case .history: openWindow(id: WindowID.history)
                case .log: openWindow(id: WindowID.log)
                case .settings: openSettings()
                }
            }
    }

    private var symbol: String {
        guard model.phase == .running, let snapshot = model.snapshot else { return "photo.on.rectangle.angled" }
        if model.visibleDecisions.isEmpty == false || snapshot.overall == .photosUnauthorized { return "exclamationmark.triangle" }
        if snapshot.overall == .paused { return "pause.circle" }
        if snapshot.overall == .syncing { return "arrow.triangle.2.circlepath" }
        return "photo.on.rectangle.angled"
    }
}
