import PhotoVaultCore
import SwiftUI

/// Flags and own-language names, so someone who cannot read the current language still finds theirs.
extension InterfaceLanguageChoice {
    var flag: String {
        switch self {
        case .system: "🌐"
        case .vi: "🇻🇳"
        case .en: "🇬🇧"
        }
    }

    var menuTitle: String {
        switch self {
        case .system: "🌐  " + tr(vi: "Theo hệ thống", en: "System")
        case .vi: "🇻🇳  Tiếng Việt" // l10n: verbatim
        case .en: "🇬🇧  English"
        }
    }
}

extension AppLanguage {
    var flag: String { self == .vi ? "🇻🇳" : "🇬🇧" }
}

/// The interface-language picker for Settings and onboarding.
struct InterfaceLanguagePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker(selection: model.interfaceLanguageBinding) {
            ForEach(InterfaceLanguageChoice.allCases, id: \.self) { Text($0.menuTitle).tag($0) }
        } label: {
            Label(tr(vi: "Ngôn ngữ giao diện", en: "Interface language"), systemImage: "globe")
        }
    }
}

/// A flag button that opens the language list; sits in the menu bar popover so it is the first
/// thing in reach whatever the language on screen.
struct LanguageMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Picker(selection: model.interfaceLanguageBinding) {
                ForEach(InterfaceLanguageChoice.allCases, id: \.self) { Text($0.menuTitle).tag($0) }
            } label: { EmptyView() }
            .pickerStyle(.inline)
        } label: {
            Text(model.language.flag).font(.title3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // Both languages on purpose: the tooltip must make sense to someone who reads neither the current one.
        .help("Ngôn ngữ giao diện · Interface language") // l10n: verbatim
        .accessibilityLabel(tr(vi: "Ngôn ngữ giao diện", en: "Interface language"))
    }
}
