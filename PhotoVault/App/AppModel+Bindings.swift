import PhotoVaultCore
import SwiftUI

extension AppModel {
    /// Two-way binding into the Settings draft; every change is validated and saved.
    func binding<Value: Sendable>(_ keyPath: WritableKeyPath<GlobalSettings, Value>) -> Binding<Value> {
        Binding(
            get: { MainActor.assumeIsolated { self.settings[keyPath: keyPath] } },
            set: { newValue in
                MainActor.assumeIsolated {
                    self.settings[keyPath: keyPath] = newValue
                    self.scheduleCommit()
                }
            })
    }
}
