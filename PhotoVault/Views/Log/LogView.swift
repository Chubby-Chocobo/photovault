import AppKit
import PhotoVaultAppSupport
import PhotoVaultCore
import SwiftUI

/// The technical log, readable without Finder: newest lines first, a level filter, search, copy.
struct LogView: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [LogEntry] = []
    @State private var level: LogLevelFilter = .standard
    @State private var query = ""
    @State private var visible: [LogEntry] = []
    @State private var copied = false
    /// Off while the owner reads older lines, so new lines do not push them down.
    @State private var following = true

    var body: some View {
        content
            .navigationTitle(tr(vi: "Nhật ký", en: "Log"))
            .id(model.language)
    }

    private func refilter() { visible = LogReader.filter(entries, level: level, query: query) }

    private var content: some View {
        VStack(spacing: 0) {
            Text(tr(
                vi: "Nhật ký kỹ thuật của PhotoVault, dùng khi cần tìm hiểu hoặc báo lỗi. Không chứa tên file, vị trí hay thông tin đăng nhập. Bấm “Sao chép” để gửi kèm khi báo lỗi.",
                en: "PhotoVault's technical log, for looking into or reporting a problem. It holds no file names, locations or sign-in details. Use “Copy” to attach it to a report."))
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 12)
            toolbar
            Divider()
            let lines = visible
            if lines.isEmpty {
                Text(entries.isEmpty
                    ? tr(vi: "Chưa có dòng log nào.", en: "The log is empty.")
                    : tr(vi: "Không có dòng nào khớp bộ lọc.", en: "No lines match the filter."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(lines) { LogRowView(entry: $0) }
                    }
                    .padding(12)
                    .textSelection(.enabled)
                }
            }
            Divider()
            Text(tr(
                vi: "\(VietnameseFormat.integer(lines.count)) dòng · hiển thị tối đa \(VietnameseFormat.integer(LogReader.defaultLimit)) dòng gần nhất · log chiếm tối đa \(VietnameseFormat.bytes(Int64(LogReader.maxDiskBytes))), phần cũ nhất tự xoá",
                en: "\(L10n.plural(lines.count, one: "1 line", other: "\(VietnameseFormat.integer(lines.count)) lines")) · showing up to the latest \(VietnameseFormat.integer(LogReader.defaultLimit)) · the log never takes more than \(VietnameseFormat.bytes(Int64(LogReader.maxDiskBytes))); the oldest part is deleted"))
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .frame(minWidth: 680, idealWidth: 820, minHeight: 440, idealHeight: 560)
        .task(id: following) { await follow() }
        .onChange(of: entries) { refilter() }
        .onChange(of: level) { refilter() }
        .onChange(of: query) { refilter() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker(tr(vi: "Mức", en: "Level"), selection: $level) {
                ForEach(LogLevelFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            TextField(tr(vi: "Tìm", en: "Search"), text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140)
                .accessibilityLabel(tr(vi: "Tìm trong log", en: "Search the log"))
            Spacer(minLength: 0)
            Toggle(tr(vi: "Tự cập nhật", en: "Live"), isOn: $following)
                .toggleStyle(.checkbox)
                .help(tr(vi: "Tắt để đọc các dòng cũ mà không bị dòng mới đẩy xuống", en: "Turn off to read older lines without new ones pushing them down"))
            Button(copied ? tr(vi: "Đã sao chép", en: "Copied") : tr(vi: "Sao chép", en: "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc") {
                copy()
            }
            .disabled(visible.isEmpty)
            .help(tr(vi: "Sao chép các dòng đang hiện", en: "Copy the lines shown"))
            Button(tr(vi: "Mở thư mục log", en: "Open log folder"), systemImage: "folder") { model.revealLog() }
                .labelStyle(.iconOnly)
                .help(tr(vi: "Mở thư mục log trong Finder", en: "Show the log folder in Finder"))
        }
        .padding(12)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(LogReader.text(visible), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2), tolerance: .milliseconds(500))
            copied = false
        }
    }

    /// Re-reads the files whenever the current one changes, off the main thread.
    private func follow() async {
        guard let directory = model.logDirectory else { return }
        let reader = LogReader(directory: directory)
        var lastStamp: String?
        while !Task.isCancelled {
            guard following || entries.isEmpty else { return }
            let stamp = reader.stamp()
            if stamp != lastStamp || entries.isEmpty {
                lastStamp = stamp
                entries = await Task.detached(priority: .utility) { reader.read() }.value
            }
            try? await Task.sleep(for: .seconds(2), tolerance: .milliseconds(500))
        }
    }
}

private struct LogRowView: View {
    var entry: LogEntry

    /// "09/11 20:04:56.512" in the Mac's time zone (the file stores UTC).
    private static let timeFormat = Date.VerbatimFormatStyle(
        format: "\(day: .twoDigits)/\(month: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits).\(secondFraction: .fractional(3))",
        timeZone: .current, calendar: .current)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.date.map { $0.formatted(Self.timeFormat) } ?? "")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 128, alignment: .leading)
            Text(levelText)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(tint.opacity(0.15), in: Capsule())
                .foregroundStyle(tint)
                .frame(width: 62, alignment: .leading)
            Text(entry.category)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
                .lineLimit(1)
            Text(entry.message)
                .font(.callout.monospaced())
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var levelText: String {
        switch entry.level {
        case .debug: tr(vi: "Chi tiết", en: "Debug")
        case .info: tr(vi: "Thông tin", en: "Info")
        case .notice: tr(vi: "Chú ý", en: "Notice")
        case .error: tr(vi: "Lỗi", en: "Error")
        case .fault: tr(vi: "Nghiêm trọng", en: "Fault")
        case nil: ""
        }
    }

    private var tint: Color {
        switch entry.level {
        case .error, .fault: .red
        case .notice: .orange
        default: .secondary
        }
    }
}
