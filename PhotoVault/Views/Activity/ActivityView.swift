import PhotoVaultAppSupport
import PhotoVaultCore
import SwiftUI

/// Recent activity (FR-63): the newest 500 events with a kind filter and search, plus any open owner prompts.
struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: ActivityFilter = .all
    @State private var query = ""

    var body: some View {
        content
            .navigationTitle(tr(vi: "Hoạt động gần đây", en: "Recent activity"))
            .id(model.language)
    }

    private var content: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    NoticeBanner()
                    ForEach(model.visibleDecisions) { DecisionCard(decision: $0) }
                    let groups = ActivityPresenter.groups(
                        model.activity, filter: filter, query: query, destinationNames: model.destinationNames, now: Date())
                    if groups.isEmpty {
                        Text(model.activity.isEmpty
                            ? tr(vi: "Chưa có sự kiện nào.", en: "No events yet.")
                            : tr(vi: "Không có sự kiện khớp bộ lọc.", en: "No events match the filter."))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.heading).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(group.rows) { ActivityRowView(row: $0) }
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            Text(tr(
                vi: "\(VietnameseFormat.integer(model.activity.count)) sự kiện · PhotoVault giữ 500 sự kiện gần nhất",
                en: "\(L10n.plural(model.activity.count, one: "1 event", other: "\(VietnameseFormat.integer(model.activity.count)) events")) · PhotoVault keeps the latest 500"))
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 440, idealHeight: 520)
        .task {
            while !Task.isCancelled {
                await model.refreshActivity()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker(tr(vi: "Loại sự kiện", en: "Event type"), selection: $filter) {
                ForEach(ActivityFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField(tr(vi: "Tìm", en: "Search"), text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .accessibilityLabel(tr(vi: "Tìm sự kiện", en: "Search events"))
        }
        .padding(12)
    }
}

private struct ActivityRowView: View {
    var row: ActivityRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(row.time).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            Text(row.kindLabel)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(tint.opacity(0.15), in: Capsule())
                .foregroundStyle(tint)
                .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.message).fixedSize(horizontal: false, vertical: true)
                if let name = row.destinationName { Text(name).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch row.kind {
        case .renamed: .accentColor
        case .moved: .secondary
        case .missingFile: .red
        case .statusChanged: .orange
        case .recovered: .green
        case .notice: .secondary
        case .milestone: .green
        }
    }
}
