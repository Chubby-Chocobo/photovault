import PhotoVaultAppSupport
import PhotoVaultCore
import SwiftUI

/// Sync mode with an asset count per option and the FR-06 note (onboarding step 5, add destination, destination detail).
struct ScopePicker: View {
    @Binding var scope: ScopeMode
    var timeZone: TimeZone
    var showCounts = true
    @State private var sinceDate = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    @State private var totalCount: Int?
    @State private var sinceCount: Int?

    private enum Mode { case full, since, newOnly }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            option(.full, "Toàn bộ thư viện", "Mọi ảnh và video hiện có, mới nhất trước.", count: totalCount)
            option(.since, "Từ một ngày", nil, count: sinceCount) {
                HStack {
                    Text("Từ")
                    DatePicker("Ngày bắt đầu", selection: $sinceDate, in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                        .onChange(of: sinceDate) { _, _ in select(.since) }
                }
            }
            option(.newOnly, "Chỉ ảnh mới", "Không backup ảnh đang có.", count: showCounts ? 0 : nil)
            Banner(.info, title: SyncModeChoice.newPhotoNote)
        }
        .onAppear {
            if case .since(let day) = scope, let date = Self.date(of: day, in: timeZone) { sinceDate = date }
        }
        .task(id: showCounts) {
            guard showCounts else { return }
            totalCount = await LibraryCounter.count(since: nil, timeZone: timeZone)
        }
        .task(id: sinceDate) {
            guard showCounts else { return }
            sinceCount = await LibraryCounter.count(since: pickedDay, timeZone: timeZone)
        }
    }

    /// The calendar day the owner sees in the picker, taken as an archive day.
    private var pickedDay: ArchiveDay {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: sinceDate)
        return ArchiveDay(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1) ?? ArchiveDay(date: sinceDate, timeZone: timeZone)
    }

    private var mode: Mode {
        switch scope {
        case .full: .full
        case .since: .since
        case .newOnly: .newOnly
        }
    }

    private func select(_ mode: Mode) {
        switch mode {
        case .full: scope = .full
        case .newOnly: scope = .newOnly
        case .since: scope = .since(pickedDay)
        }
    }

    private func option(
        _ value: Mode, _ title: String, _ detail: String?, count: Int?, @ViewBuilder extra: () -> some View = { EmptyView() }
    ) -> some View {
        Button { select(value) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: mode == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(mode == value ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    extra()
                }
                Spacer(minLength: 0)
                if showCounts, let count { Text("\(VietnameseFormat.integer(count)) asset").monospacedDigit().foregroundStyle(.secondary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == value ? .isSelected : [])
    }

    private static func date(of day: ArchiveDay, in zone: TimeZone) -> Date? {
        Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: day.day))
    }
}
