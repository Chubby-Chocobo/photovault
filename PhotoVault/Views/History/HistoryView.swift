import PhotoVaultAppSupport
import PhotoVaultCore
import SwiftUI

/// The History window: what was synced from Photos, each backfill run, and each one-time import. File names
/// appear here and in a CSV the owner saves, nowhere else.
struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            NoticeBanner()
            TabView {
                PhotosHistoryTab()
                    .tabItem { Text("Photos") }
                BackfillHistoryTab()
                    .tabItem { Text("Backfill") }
                ImportHistoryTab()
                    .tabItem { Text("Import") }
            }
            .padding(.top, 6)
        }
        .frame(minWidth: 900, idealWidth: 1_080, minHeight: 560, idealHeight: 700)
        .navigationTitle(tr(vi: "Lịch sử", en: "History"))
        .id(model.language)
    }
}
