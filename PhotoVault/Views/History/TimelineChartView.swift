import Charts
import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultStore
import SwiftUI

/// Files and bytes uploaded per local day, for the last 30, 90 or 365 days.
struct TimelineChartView: View {
    enum Metric: String, CaseIterable, Identifiable {
        case files, bytes
        var id: String { rawValue }
        var label: String {
            switch self {
            case .files: tr(vi: "Số file", en: "Files")
            case .bytes: tr(vi: "Dung lượng", en: "Size")
            }
        }
    }

    @Environment(AppModel.self) private var model
    var destinationId: DestinationID?
    var sourceId: SourceID?
    var refresh = 0
    @State private var span = 30
    @State private var metric: Metric = .files
    @State private var days: [TimelineDay] = []
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if failed {
                    Text(HistoryText.readFailed).font(.callout).foregroundStyle(.red)
                } else {
                    Text(HistoryTimeline.total(days)).font(.callout.weight(.medium))
                }
                Spacer()
                Picker(tr(vi: "Hiển thị", en: "Show"), selection: $metric) {
                    ForEach(Metric.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Picker(tr(vi: "Khoảng", en: "Span"), selection: $span) {
                    Text(tr(vi: "30 ngày", en: "30 days")).tag(30)
                    Text(tr(vi: "90 ngày", en: "90 days")).tag(90)
                    Text(tr(vi: "1 năm", en: "1 year")).tag(365)
                }
                .labelsHidden().fixedSize()
            }
            Chart(days) { day in
                BarMark(
                    x: .value(tr(vi: "Ngày", en: "Day"), day.day, unit: .day),
                    y: .value(metric.label, metric == .files ? Double(day.files) : Double(day.bytes) / Double(VietnameseFormat.GiB)))
                    .foregroundStyle(Color.accentColor)
            }
            .chartYAxisLabel(metric == .files ? tr(vi: "file", en: "files") : "GB")
            .frame(height: 120)
        }
        .task(id: TaskKey(span: span, destination: destinationId, refresh: refresh)) { await load() }
    }

    private struct TaskKey: Equatable {
        var span: Int
        var destination: DestinationID?
        var refresh: Int
    }

    private func load() async {
        let calendar = Calendar.current
        let range = HistoryTimeline.range(days: span, now: Date(), calendar: calendar)
        let destination = destinationId
        let source = sourceId
        do {
            let slots = try await model.historyRead { db in
                try HistoryRepository.timeline(db, from: range.from, until: range.until, destinationId: destination, sourceId: source)
            } ?? []
            days = HistoryTimeline.days(slots, from: range.from, until: range.until, calendar: calendar)
            failed = false
        } catch is CancellationError {
        } catch {
            days = []
            failed = true
        }
    }
}
