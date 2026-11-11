import PhotoVaultAppSupport
import PhotoVaultCore
import SwiftUI

/// Files of the Photos library and what happened to them at each destination, with the daily timeline.
struct PhotosHistoryTab: View {
    @Environment(AppModel.self) private var model
    var refresh = 0
    @State private var filter = HistoryFilterState()
    @State private var list = EventListModel()
    @State private var showsTimeline = true

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HistoryFilterBar(state: $filter, destinations: model.destinations)
                DisclosureGroup(tr(vi: "Dòng thời gian theo ngày", en: "Daily timeline"), isExpanded: $showsTimeline) {
                    TimelineChartView(destinationId: filter.destinationId, sourceId: .photos, refresh: refresh).padding(.top, 4)
                }
                HStack {
                    Spacer()
                    Button(tr(vi: "Xuất CSV…", en: "Export CSV…"), systemImage: "square.and.arrow.up") {
                        Task { await list.exportCSV(app: model, suggestedName: "PhotoVault-history.csv") }
                    }
                    .disabled(list.rows.isEmpty || list.isLoading)
                    .help(tr(vi: "Lưu danh sách đang xem thành file CSV", en: "Save the list shown as a CSV file"))
                }
            }
            .padding(12)
            Divider()
            EventListView(list: list)
        }
        .task(id: TaskKey(filter: filter, refresh: refresh)) {
            // Typing in the search field reloads once the owner pauses.
            if !filter.search.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await list.reload(filter.filter(scope: .photos, now: Date(), calendar: .current), app: model)
        }
    }

    private struct TaskKey: Equatable {
        var filter: HistoryFilterState
        var refresh: Int
    }
}
