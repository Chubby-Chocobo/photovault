import SwiftUI

@main
struct PhotoVaultApp: App {
    var body: some Scene {
        MenuBarExtra("PhotoVault", systemImage: "photo.on.rectangle.angled") {
            Text("PhotoVault")
            Divider()
            Button("Thoát") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
