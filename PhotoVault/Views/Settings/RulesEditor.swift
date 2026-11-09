import PhotoVaultAppSupport
import PhotoVaultCore
import SwiftUI

/// Per-destination content rules (FR-72) with the global ceiling explained: a row whose global switch is off is locked.
struct RulesEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var rules: DestinationRules
    var settings: GlobalSettings

    var body: some View {
        SettingsSection(tr(vi: "Rule nội dung", en: "Content rules")) {
            HStack(spacing: 4) {
                Text(tr(vi: "Setting ở tab", en: "The setting in the"))
                Button(tr(vi: "Nội dung", en: "Content")) { model.settingsTab = .content }.buttonStyle(.link)
                Text(tr(vi: "là trần toàn cục: một loại chỉ tới đích này khi bật ở cả hai nơi. Ô bị khoá là loại đang tắt ở Nội dung.", en: "tab is the global limit: a kind reaches this destination only when it is on in both places. A locked box is a kind turned off in Content."))
            }
            .font(.caption).foregroundStyle(.secondary)
            ForEach(RuleKey.groups, id: \.title) { group in
                HStack(alignment: .firstTextBaseline) {
                    Text(group.title).frame(width: 90, alignment: .leading).foregroundStyle(.secondary)
                    ForEach(group.keys, id: \.self) { key in
                        let blocked = RuleEditor.ceilingBlocks(key, settings: settings)
                        Toggle(isOn: Binding(
                            get: { rules.isOn(key) && !blocked },
                            set: { rules.set(key, $0) })
                        ) {
                            Text(key.label + (blocked ? tr(vi: " · trần tắt", en: " · limit off") : ""))
                        }
                        .disabled(blocked)
                        .help(blocked ? tr(vi: "Đang tắt ở Nội dung (trần toàn cục)", en: "Off in Content (global limit)") : "")
                    }
                }
            }
            HStack {
                Toggle(tr(vi: "Bỏ qua file lớn hơn", en: "Skip files larger than"), isOn: Binding(
                    get: { rules.skipLargerThanGB != nil },
                    set: { rules.skipLargerThanGB = $0 ? (rules.skipLargerThanGB ?? 4) : nil }))
                TextField("", value: Binding(get: { rules.skipLargerThanGB ?? 4 }, set: { rules.skipLargerThanGB = $0 }), format: .number)
                    .frame(width: 60).multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder)
                    .disabled(rules.skipLargerThanGB == nil).accessibilityLabel(tr(vi: "Ngưỡng GB", en: "GB threshold"))
                Text("GB")
            }
            Text(tr(vi: "Hiệu lực: ", en: "Effective: ") + RuleEditor.effectiveSummary(rules: rules, settings: settings)).font(.caption)
        }
    }
}
