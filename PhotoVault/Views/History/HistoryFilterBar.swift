import PhotoVaultAppSupport
import PhotoVaultCore
import SwiftUI

/// Search and filters of the Photos and Backfill lists: name, destination, result, kind, time, capture date,
/// and files deleted from Photos.
struct HistoryFilterBar: View {
    @Binding var state: HistoryFilterState
    var destinations: [DestinationRecord]
    @State private var limitCapture = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField(tr(vi: "Tìm theo tên file", en: "Search file names"), text: $state.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 160)
                Picker(tr(vi: "Đích", en: "Destination"), selection: $state.destinationId) {
                    Text(tr(vi: "Mọi đích", en: "All destinations")).tag(DestinationID?.none)
                    ForEach(destinations) { Text($0.displayName).tag(Optional($0.id)) }
                }
                .fixedSize()
                Picker(tr(vi: "Kết quả", en: "Result"), selection: $state.outcome) {
                    Text(tr(vi: "Mọi kết quả", en: "All results")).tag(TransferOutcome?.none)
                    ForEach(TransferOutcome.allCases, id: \.self) { Text(HistoryText.outcome($0)).tag(Optional($0)) }
                }
                .fixedSize()
            }
            HStack(spacing: 10) {
                Picker(tr(vi: "Loại", en: "Type"), selection: $state.media) {
                    ForEach(HistoryMediaFilter.allCases, id: \.self) { Text(HistoryText.media($0)).tag($0) }
                }
                .fixedSize()
                Picker(tr(vi: "Thời gian", en: "When"), selection: $state.timeRange) {
                    ForEach(HistoryTimeRange.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                Toggle(tr(vi: "Ngày chụp", en: "Taken"), isOn: $limitCapture)
                    .toggleStyle(.checkbox)
                if limitCapture {
                    DatePicker(tr(vi: "Từ", en: "From"), selection: day(\.capturedFrom), displayedComponents: .date)
                        .fixedSize()
                    DatePicker(tr(vi: "đến", en: "to"), selection: day(\.capturedTo), displayedComponents: .date)
                        .fixedSize()
                }
                Toggle(tr(vi: "Đã xoá khỏi Photos", en: "Deleted from Photos"), isOn: $state.deletedFromLibraryOnly)
                    .toggleStyle(.checkbox)
                    .help(HistoryText.deletedFromLibrary)
                Spacer(minLength: 0)
            }
        }
        .onChange(of: limitCapture) { _, on in
            state.capturedFrom = on ? Calendar.current.date(byAdding: .month, value: -1, to: Date()) : nil
            state.capturedTo = on ? Date() : nil
        }
    }

    /// A date picker for an optional day of the state; only shown while the capture filter is on.
    private func day(_ keyPath: WritableKeyPath<HistoryFilterState, Date?>) -> Binding<Date> {
        Binding(get: { state[keyPath: keyPath] ?? Date() }, set: { state[keyPath: keyPath] = $0 })
    }
}
