import SwiftUI
import PhotoVaultCore

/// Actions list of the popover (FR-60): Pause/Resume all, Drive, NAS, activity, Settings, log, Quit.
struct MenuBarActions: View {
    @Environment(AppModel.self) private var model
    @State private var showNasList = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.phase == .running {
                row(model.isPausedAll ? tr(vi: "Tiếp tục tất cả", en: "Resume all") : tr(vi: "Tạm dừng tất cả", en: "Pause all"), model.isPausedAll ? "play.fill" : "pause.fill") {
                    model.isPausedAll ? model.resumeAll() : model.pauseAll()
                }
                row(tr(vi: "Mở Google Drive", en: "Open Google Drive"), "icloud") { model.openGoogleDrive() }
                    .disabled(model.driveRecord?.config.driveRootId == nil)
                if !model.localRecords.isEmpty {
                    row(tr(vi: "Mở thư mục NAS trong Finder", en: "Show NAS folder in Finder"), "externaldrive") {
                        if model.localRecords.count == 1, let only = model.localRecords.first {
                            model.revealInFinder(only)
                        } else {
                            showNasList.toggle()
                        }
                    }
                    if showNasList {
                        ForEach(model.localRecords) { record in
                            Button { model.revealInFinder(record) } label: {
                                HStack {
                                    Text(record.displayName)
                                    Spacer()
                                    Text(record.config.displayPath ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .padding(.leading, 26)
                            }
                            .buttonStyle(.plain)
                            .disabled(record.status.reason == .offline)
                        }
                    }
                }
                row(tr(vi: "Hoạt động gần đây…", en: "Recent activity…"), "clock.arrow.circlepath") { model.open(.activity) }
            }
            row("Settings…", "gearshape", shortcut: "⌘,") { model.open(.settings(model.settingsTab)) }
                .keyboardShortcut(",")
            row(tr(vi: "Xem log", en: "View log"), "doc.text.magnifyingglass") { model.open(.log) }
            Divider().padding(.vertical, 2)
            row(tr(vi: "Thoát PhotoVault", en: "Quit PhotoVault"), "power", shortcut: "⌘Q") { model.quit() }
                .keyboardShortcut("q")
        }
    }

    private func row(_ title: String, _ symbol: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).font(.caption).foregroundStyle(.tertiary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }
}
