import SwiftUI

/// The Settings scene: toolbar-style tabs as in settings.html.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                SettingsTabContent(tab: tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab)
            }
        }
        .frame(width: 720, height: 560)
        .task { await model.refresh() }
    }
}

private struct SettingsTabContent: View {
    var tab: SettingsTab

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                NoticeBanner()
                SettingsIssuesBanner()
                switch tab {
                case .general: GeneralTab()
                case .content: ContentTab()
                case .organization: OrganizationTab()
                case .places: PlacesTab()
                case .destinations: DestinationsTab()
                case .advanced: AdvancedTab()
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Section header with an optional FR tag, matching the grouped forms of the mockup.
struct SettingsSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Footnote under a section.
struct SettingsNote: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Shown on every tab while a field is invalid: the other changes are saved, that field is not.
private struct SettingsIssuesBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.settingsIssues.isEmpty {
            Banner(.warning, title: "Một số thay đổi chưa được lưu",
                   message: model.settingsIssues.map(\.message).joined(separator: " ")
                       + " Các thay đổi khác đã được lưu.")
        }
    }
}
