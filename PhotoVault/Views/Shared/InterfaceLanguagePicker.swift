import PhotoVaultCore
import SwiftUI

/// System / Tiếng Việt / English. Language names are written in their own language.
struct InterfaceLanguagePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker(tr(vi: "Ngôn ngữ giao diện", en: "Interface language"), selection: model.interfaceLanguageBinding) {
            Text(tr(vi: "Theo hệ thống", en: "System")).tag(InterfaceLanguageChoice.system)
            Text("Tiếng Việt").tag(InterfaceLanguageChoice.vi) // l10n: verbatim
            Text("English").tag(InterfaceLanguageChoice.en)
        }
    }
}
