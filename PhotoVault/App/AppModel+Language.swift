import Foundation
import PhotoVaultCore
import SwiftUI

/// The interface language (Settings › General): stored per Mac in UserDefaults because it is needed
/// before the database opens. Changing it takes effect at once; destination folder names never
/// depend on it.
extension AppModel {
    static let interfaceLanguageKey = "PVInterfaceLanguage"

    static func storedInterfaceLanguage(_ defaults: UserDefaults = .standard) -> InterfaceLanguageChoice {
        defaults.string(forKey: interfaceLanguageKey).flatMap(InterfaceLanguageChoice.init(rawValue:)) ?? .vi
    }

    /// Applies `choice` to everything built from now on and re-renders the open windows.
    func setInterfaceLanguage(_ choice: InterfaceLanguageChoice, save: Bool = true) {
        interfaceLanguage = choice
        let resolved = choice.resolved(preferredLanguages: Locale.preferredLanguages)
        L10n.current = resolved
        language = resolved
        if save { UserDefaults.standard.set(choice.rawValue, forKey: Self.interfaceLanguageKey) }
    }

    var interfaceLanguageBinding: Binding<InterfaceLanguageChoice> {
        Binding(get: { self.interfaceLanguage }, set: { self.setInterfaceLanguage($0) })
    }
}
