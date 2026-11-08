import PhotoVaultAppSupport
import PhotoVaultCore
import SwiftUI

/// Per-destination content rules (FR-72) with the global ceiling explained: a row whose global switch is off is locked.
struct RulesEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var rules: DestinationRules
    var settings: GlobalSettings

    var body: some View {
        SettingsSection("Rule nội dung") {
            HStack(spacing: 4) {
                Text("Setting ở tab")
                Button("Nội dung") { model.settingsTab = .content }.buttonStyle(.link)
                Text("là trần toàn cục: một loại chỉ tới đích này khi bật ở cả hai nơi. Ô bị khoá là loại đang tắt ở Nội dung.")
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
                            Text(key.label + (blocked ? " · trần tắt" : ""))
                        }
                        .disabled(blocked)
                        .help(blocked ? "Đang tắt ở Nội dung (trần toàn cục)" : "")
                    }
                }
            }
            HStack {
                Toggle("Bỏ qua file lớn hơn", isOn: Binding(
                    get: { rules.skipLargerThanGB != nil },
                    set: { rules.skipLargerThanGB = $0 ? (rules.skipLargerThanGB ?? 4) : nil }))
                TextField("", value: Binding(get: { rules.skipLargerThanGB ?? 4 }, set: { rules.skipLargerThanGB = $0 }), format: .number)
                    .frame(width: 60).multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder)
                    .disabled(rules.skipLargerThanGB == nil).accessibilityLabel("Ngưỡng GB")
                Text("GB")
            }
            Text("Hiệu lực: " + RuleEditor.effectiveSummary(rules: rules, settings: settings)).font(.caption)
        }
    }
}
