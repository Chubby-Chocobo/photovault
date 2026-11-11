import PhotoVaultAppSupport
import PhotoVaultCore
import SwiftUI

/// The History window: what was synced from Photos, each backfill run, and each one-time import. File names
/// appear here and in a CSV the owner saves, nowhere else.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    /// Bumped by "Làm mới": every tab reloads what it shows.
    @State private var refresh = 0

    var body: some View {
        VStack(spacing: 0) {
            NoticeBanner()
            TabView {
                PhotosHistoryTab(refresh: refresh)
                    .tabItem { Text("Photos") }
                BackfillHistoryTab(refresh: refresh)
                    .tabItem { Text("Backfill") }
                ImportHistoryTab(refresh: refresh)
                    .tabItem { Text("Import") }
            }
            .padding(.top, 6)
        }
        .frame(minWidth: 900, idealWidth: 1_080, minHeight: 560, idealHeight: 700)
        .toolbar {
            Button(tr(vi: "Làm mới", en: "Refresh"), systemImage: "arrow.clockwise") { refresh += 1 }
                .help(tr(vi: "Đọc lại lịch sử", en: "Read the history again"))
        }
        .navigationTitle(tr(vi: "Lịch sử", en: "History"))
        .id(model.language)
    }
}
