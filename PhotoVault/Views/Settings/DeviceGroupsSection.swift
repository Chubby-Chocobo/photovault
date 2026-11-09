import PhotoVaultAppSupport
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
        SettingsSection("Nhóm thiết bị (By device)") {
            if groups.isEmpty {
                Text("Chưa có ảnh camera nào được phân nhóm.").foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if editing == group.id {
                            TextField("Tên nhóm", text: $draft).textFieldStyle(.roundedBorder).frame(width: 220)
                                .onSubmit { Task { await save(group) } }
                            Button("Lưu") { Task { await save(group) } }
                            Button("Huỷ") { editing = nil; clash = nil }
                        } else {
                            VStack(alignment: .leading) {
                                Text(group.name)
                                Text("\(group.models.count) model · \(VietnameseFormat.integer(group.assetCount)) asset")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Đổi tên") { editing = group.id; draft = group.name; clash = nil }
                            Button("Gộp vào…") { openMerge(group, preferred: nil) }.disabled(groups.count < 2)
                        }
                    }
                    if editing == group.id, let clashId = clash, let other = groups.first(where: { $0.id == clashId }) {
                        HStack {
                            Text("Trùng tên với nhóm “\(other.name)”.").font(.caption).foregroundStyle(.red)
                            Button("Gộp vào nhóm đó") { openMerge(group, preferred: clashId) }.controlSize(.small)
                        }
                    }
                }
            }
            SettingsNote("Đổi tên = đổi tên thư mục trên Drive. Gộp = gán model sang nhóm khác và chuyển shortcut.")
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
            Text("Gộp “\(source.name)”").font(.title3.weight(.semibold))
            Picker("Nhóm đích", selection: $target) {
                ForEach(others) { Text($0.name).tag(Optional($0.id)) }
            }
            if let target, let name = others.first(where: { $0.id == target })?.name {
                Text("Gán model vào nhóm “\(name)” và chuyển \(VietnameseFormat.integer(source.assetCount)) shortcut sang By device/\(name)/.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Huỷ") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Gộp") { onConfirm() }.keyboardShortcut(.defaultAction).disabled(target == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
