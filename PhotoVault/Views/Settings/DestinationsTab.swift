import PhotoVaultAppSupport
import PhotoVaultCore
import SwiftUI

/// Settings › Đích: the destination list with add / remove / pause, and the selected destination's detail (FR-70..72).
struct DestinationsTab: View {
    @Environment(AppModel.self) private var model
    @State private var selection: DestinationID?
    @State private var pending: PendingLocalDestination?
    @State private var confirmRemove = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 6) {
                List(model.destinations, id: \.id, selection: $selection) { record in
                    let status = StatusText.presentation(for: record.status)
                    HStack(spacing: 8) {
                        Image(systemName: record.kind == .googleDrive ? "icloud" : "externaldrive").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(record.displayName)
                            HStack(spacing: 4) { StatusDot(color: status.tone.color); Text(status.label).font(.caption2) }
                        }
                    }
                    .tag(record.id)
                }
                .frame(width: 210, height: 300)
                .accessibilityLabel(tr(vi: "Danh sách đích", en: "Destination list"))
                HStack {
                    Button { Task { pending = await model.pickLocalFolder() } } label: { Image(systemName: "plus") }
                        .accessibilityLabel(tr(vi: "Thêm đích", en: "Add destination"))
                    Button { confirmRemove = true } label: { Image(systemName: "minus") }
                        .disabled(selectedRecord?.kind != .localFolder)
                        .accessibilityLabel(tr(vi: "Xoá đích", en: "Remove destination"))
                    Spacer()
                    if let record = selectedRecord {
                        Button(model.isOwnerPaused(record) ? tr(vi: "Tiếp tục", en: "Resume") : tr(vi: "Tạm dừng", en: "Pause")) { model.togglePause(record) }
                    }
                }
                .frame(width: 210)
            }
            if let record = selectedRecord {
                DestinationDetail(record: record).id(record.id)
            } else {
                Text(tr(vi: "Chọn một đích ở bên trái.", en: "Select a destination on the left.")).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .onAppear { selection = selection ?? model.destinations.first?.id }
        .sheet(item: $pending) { item in AddDestinationSheet(pending: item) { pending = nil } }
        .confirmationDialog(
            tr(vi: "Xoá “\(selectedRecord?.displayName ?? "")” khỏi PhotoVault?", en: "Remove “\(selectedRecord?.displayName ?? "")” from PhotoVault?"), isPresented: $confirmRemove, titleVisibility: .visible
        ) {
            Button(tr(vi: "Xoá đích", en: "Remove destination"), role: .destructive) {
                if let record = selectedRecord { Task { await model.removeDestination(record); selection = model.destinations.first?.id } }
            }
            Button(tr(vi: "Huỷ", en: "Cancel"), role: .cancel) {}
        } message: {
            Text(tr(
                vi: "PhotoVault chỉ xoá trạng thái của đích này trong cơ sở dữ liệu. Không xoá file nào trong \(selectedRecord?.config.displayPath ?? "thư mục đích").",
                en: "PhotoVault only removes this destination's state from its database. No files in \(selectedRecord?.config.displayPath ?? "the destination folder") are deleted."))
        }
    }

    private var selectedRecord: DestinationRecord? { model.destinations.first { $0.id == selection } }
}

private struct DestinationDetail: View {
    @Environment(AppModel.self) private var model
    var record: DestinationRecord
    @State private var rules: DestinationRules
    @State private var scope: ScopeMode
    @State private var name: String
    @State private var counts: [RuleKey: Int] = [:]
    @State private var freeBytes: Int64?

    init(record: DestinationRecord) {
        self.record = record
        _rules = State(initialValue: record.rules)
        _scope = State(initialValue: record.scope)
        _name = State(initialValue: record.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            SettingsSection(tr(vi: "Phạm vi", en: "Scope")) {
                ScopePicker(scope: $scope, timeZone: model.archiveTimeZone)
            }
            RulesEditor(rules: $rules, settings: model.persistedSettings)
            let lines = RuleEditor.changeLines(
                old: record.rules, new: rules, oldScope: record.scope, newScope: scope, settings: model.persistedSettings, counts: counts)
            if !lines.isEmpty {
                Banner(.warning, title: tr(vi: "Thay đổi chưa áp dụng", en: "Unapplied changes"), message: lines.joined(separator: "\n") + tr(vi: "\nKhông xoá gì ở đích. Job đã xong giữ nguyên.", en: "\nNothing at the destination is deleted. Finished jobs stay as they are.")) {
                    HStack {
                        Button(tr(vi: "Huỷ", en: "Cancel")) { rules = record.rules; scope = record.scope; name = record.displayName }
                        Button(tr(vi: "Áp dụng", en: "Apply")) { Task { await model.updateDestination(record.id, name: name, rules: rules, scope: scope) } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else if name != record.displayName {
                Button(tr(vi: "Lưu tên", en: "Save name")) { Task { await model.updateDestination(record.id, name: name, rules: rules, scope: scope) } }
            }
        }
        .task {
            counts = await model.ruleCounts()
            freeBytes = await model.freeSpace(of: record)
        }
    }

    private var header: some View {
        SettingsSection(record.kind == .googleDrive ? "Google Drive" : tr(vi: "Thư mục", en: "Folder")) {
            if record.kind == .localFolder {
                FormRow(tr(vi: "Tên", en: "Name")) { TextField(tr(vi: "Tên đích", en: "Destination name"), text: $name).textFieldStyle(.roundedBorder).frame(width: 240) }
            }
            FormRow(record.kind == .googleDrive ? "My Drive / \(record.config.driveRootName ?? "—")" : (record.config.displayPath ?? "—")) {
                let status = StatusText.presentation(for: record.status)
                HStack(spacing: 5) { StatusDot(color: status.tone.color); Text(status.label) }
            }
            FormRow(tr(vi: "Dung lượng trống", en: "Free space")) { Text(freeBytes.map(VietnameseFormat.bytes) ?? "—").monospacedDigit() }
            HStack {
                Button("Test connection") { Task { await model.testConnection(record) } }
                if record.kind == .localFolder {
                    Button(tr(vi: "Chọn lại thư mục…", en: "Choose folder again…")) { Task { await model.repickFolder(for: record) } }
                    Button(tr(vi: "Mở trong Finder", en: "Show in Finder")) { model.revealInFinder(record) }
                }
            }
            if record.status == .paused(.userPaused) || model.isOwnerPaused(record) {
                SettingsNote(tr(vi: "Đích đang tạm dừng độc lập với các đích khác (FR-71).", en: "This destination is paused independently of the others (FR-71)."))
            }
        }
    }
}
