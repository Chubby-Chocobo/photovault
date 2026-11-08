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
                .accessibilityLabel("Danh sách đích")
                HStack {
                    Button { Task { pending = await model.pickLocalFolder() } } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Thêm đích")
                    Button { confirmRemove = true } label: { Image(systemName: "minus") }
                        .disabled(selectedRecord?.kind != .localFolder)
                        .accessibilityLabel("Xoá đích")
                    Spacer()
                    if let record = selectedRecord {
                        Button(model.isOwnerPaused(record) ? "Tiếp tục" : "Tạm dừng") { model.togglePause(record) }
                    }
                }
                .frame(width: 210)
            }
            if let record = selectedRecord {
                DestinationDetail(record: record).id(record.id)
            } else {
                Text("Chọn một đích ở bên trái.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .onAppear { selection = selection ?? model.destinations.first?.id }
        .sheet(item: $pending) { item in AddDestinationSheet(pending: item) { pending = nil } }
        .confirmationDialog(
            "Xoá “\(selectedRecord?.displayName ?? "")” khỏi PhotoVault?", isPresented: $confirmRemove, titleVisibility: .visible
        ) {
            Button("Xoá đích", role: .destructive) {
                if let record = selectedRecord { Task { await model.removeDestination(record); selection = model.destinations.first?.id } }
            }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("PhotoVault chỉ xoá trạng thái của đích này trong cơ sở dữ liệu. Không xoá file nào trong \(selectedRecord?.config.displayPath ?? "thư mục đích").")
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
            SettingsSection("Phạm vi") {
                ScopePicker(scope: $scope, timeZone: model.archiveTimeZone)
            }
            RulesEditor(rules: $rules, settings: model.persistedSettings)
            let lines = RuleEditor.changeLines(
                old: record.rules, new: rules, oldScope: record.scope, newScope: scope, settings: model.persistedSettings, counts: counts)
            if !lines.isEmpty {
                Banner(.warning, title: "Thay đổi chưa áp dụng", message: lines.joined(separator: "\n") + "\nKhông xoá gì ở đích. Job đã xong giữ nguyên.") {
                    HStack {
                        Button("Huỷ") { rules = record.rules; scope = record.scope; name = record.displayName }
                        Button("Áp dụng") { Task { await model.updateDestination(record.id, name: name, rules: rules, scope: scope) } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else if name != record.displayName {
                Button("Lưu tên") { Task { await model.updateDestination(record.id, name: name, rules: rules, scope: scope) } }
            }
        }
        .task {
            counts = await model.ruleCounts()
            freeBytes = await model.freeSpace(of: record)
        }
    }

    private var header: some View {
        SettingsSection(record.kind == .googleDrive ? "Google Drive" : "Thư mục") {
            if record.kind == .localFolder {
                FormRow("Tên") { TextField("Tên đích", text: $name).textFieldStyle(.roundedBorder).frame(width: 240) }
            }
            FormRow(record.kind == .googleDrive ? "My Drive / \(record.config.driveRootName ?? "—")" : (record.config.displayPath ?? "—")) {
                let status = StatusText.presentation(for: record.status)
                HStack(spacing: 5) { StatusDot(color: status.tone.color); Text(status.label) }
            }
            FormRow("Dung lượng trống") { Text(freeBytes.map(VietnameseFormat.bytes) ?? "—").monospacedDigit() }
            HStack {
                Button("Test connection") { Task { await model.testConnection(record) } }
                if record.kind == .localFolder {
                    Button("Chọn lại thư mục…") { Task { await model.repickFolder(for: record) } }
                    Button("Mở trong Finder") { model.revealInFinder(record) }
                }
            }
            if record.status == .paused(.userPaused) || model.isOwnerPaused(record) {
                SettingsNote("Đích đang tạm dừng độc lập với các đích khác (FR-71).")
            }
        }
    }
}
