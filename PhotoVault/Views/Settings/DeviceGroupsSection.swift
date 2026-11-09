import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultEngine
import SwiftUI

/// "Nhóm thiết bị (By device)" (FR-104): rename (a clash suggests a merge) and merge.
struct DeviceGroupsSection: View {
    @Environment(AppModel.self) private var model
    @State private var groups: [AppQueries.DeviceGroupInfo] = []
    @State private var editing: String?
    @State private var draft = ""
    @State private var clash: String?
    @State private var mergeSource: AppQueries.DeviceGroupInfo?
    @State private var mergeTarget: String?

    var body: some View {
        SettingsSection(tr(vi: "Nhóm thiết bị (By device)", en: "Device groups (By device)")) {
            if groups.isEmpty {
                Text(tr(vi: "Chưa có ảnh camera nào được phân nhóm.", en: "No camera photos have been grouped yet.")).foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if editing == group.id {
                            TextField(tr(vi: "Tên nhóm", en: "Group name"), text: $draft).textFieldStyle(.roundedBorder).frame(width: 220)
                                .onSubmit { Task { await save(group) } }
                            Button(tr(vi: "Lưu", en: "Save")) { Task { await save(group) } }
                            Button(tr(vi: "Huỷ", en: "Cancel")) { editing = nil; clash = nil }
                        } else {
                            VStack(alignment: .leading) {
                                Text(group.name)
                                Text(tr(
                                    vi: "\(group.models.count) model · \(VietnameseFormat.integer(group.assetCount)) asset",
                                    en: "\(L10n.plural(group.models.count, one: "1 model", other: "\(group.models.count) models")) · \(L10n.plural(group.assetCount, one: "1 asset", other: "\(VietnameseFormat.integer(group.assetCount)) assets"))"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(tr(vi: "Đổi tên", en: "Rename")) { editing = group.id; draft = group.name; clash = nil }
                            Button(tr(vi: "Gộp vào…", en: "Merge into…")) { openMerge(group, preferred: nil) }.disabled(groups.count < 2)
                        }
                    }
                    if editing == group.id, let clashId = clash, let other = groups.first(where: { $0.id == clashId }) {
                        HStack {
                            Text(tr(vi: "Trùng tên với nhóm “\(other.name)”.", en: "Same name as the group “\(other.name)”.")).font(.caption).foregroundStyle(.red)
                            Button(tr(vi: "Gộp vào nhóm đó", en: "Merge into that group")) { openMerge(group, preferred: clashId) }.controlSize(.small)
                        }
                    }
                }
            }
            SettingsNote(tr(vi: "Đổi tên = đổi tên thư mục trên Drive. Gộp = gán model sang nhóm khác và chuyển shortcut.", en: "Renaming renames the folder on Drive. Merging assigns the models to another group and moves the shortcuts."))
        }
        .task { groups = await model.deviceGroups() }
        .sheet(item: $mergeSource) { source in
            MergeSheet(source: source, others: groups.filter { $0.id != source.id }, target: $mergeTarget) {
                Task {
                    if let target = mergeTarget { await model.mergeDeviceModels(source.models.map(\.key), into: target) }
                    mergeSource = nil
                    editing = nil
                    groups = await model.deviceGroups()
                }
            }
        }
    }

    private func save(_ group: AppQueries.DeviceGroupInfo) async {
        if let error = await model.renameDeviceGroup(group.id, to: draft) {
            switch error {
            case .duplicateName(let existing): clash = existing
            default: model.showError(error)
            }
            return
        }
        editing = nil
        clash = nil
        groups = await model.deviceGroups()
    }

    private func openMerge(_ group: AppQueries.DeviceGroupInfo, preferred: String?) {
        mergeTarget = preferred ?? groups.first { $0.id != group.id }?.id
        mergeSource = group
    }
}

private struct MergeSheet: View {
    var source: AppQueries.DeviceGroupInfo
    var others: [AppQueries.DeviceGroupInfo]
    @Binding var target: String?
    var onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr(vi: "Gộp “\(source.name)”", en: "Merge “\(source.name)”")).font(.title3.weight(.semibold))
            Picker(tr(vi: "Nhóm đích", en: "Target group"), selection: $target) {
                ForEach(others) { Text($0.name).tag(Optional($0.id)) }
            }
            if let target, let name = others.first(where: { $0.id == target })?.name {
                Text(tr(
                    vi: "Gán model vào nhóm “\(name)” và chuyển \(VietnameseFormat.integer(source.assetCount)) shortcut sang By device/\(name)/.",
                    en: "Assigns the models to the group “\(name)” and moves \(L10n.plural(source.assetCount, one: "1 shortcut", other: "\(VietnameseFormat.integer(source.assetCount)) shortcuts")) to By device/\(name)/."))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(tr(vi: "Huỷ", en: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr(vi: "Gộp", en: "Merge")) { onConfirm() }.keyboardShortcut(.defaultAction).disabled(target == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
