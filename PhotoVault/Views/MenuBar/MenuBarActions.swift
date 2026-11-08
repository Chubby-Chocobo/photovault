import SwiftUI

/// Actions list of the popover (FR-60): Pause/Resume all, Drive, NAS, activity, Settings, log, Quit.
struct MenuBarActions: View {
    @Environment(AppModel.self) private var model
    @State private var showNasList = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.phase == .running {
                row(model.isPausedAll ? "Tiếp tục tất cả" : "Tạm dừng tất cả", model.isPausedAll ? "play.fill" : "pause.fill") {
                    model.isPausedAll ? model.resumeAll() : model.pauseAll()
                }
                row("Mở Google Drive", "icloud") { model.openGoogleDrive() }
                    .disabled(model.driveRecord?.config.driveRootId == nil)
                if !model.localRecords.isEmpty {
                    row("Mở thư mục NAS trong Finder", "externaldrive") {
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
                row("Hoạt động gần đây…", "clock.arrow.circlepath") { model.open(.activity) }
            }
            row("Settings…", "gearshape", shortcut: "⌘,") { model.open(.settings(model.settingsTab)) }
                .keyboardShortcut(",")
            row("Xem log", "doc.text.magnifyingglass") { model.revealLog() }
            Divider().padding(.vertical, 2)
            row("Thoát PhotoVault", "power", shortcut: "⌘Q") { model.quit() }
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
