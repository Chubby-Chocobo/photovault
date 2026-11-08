import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultDrive
import SwiftUI

/// FR-08: sign in with another account, then choose where its backups go.
struct AccountChangeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage = .confirm
    @State private var change: AccountChange?
    @State private var roots: [RootChooser.RemoteItemSummary] = []
    @State private var reuseRootId: String?
    @State private var newName = "Camera Uploads"
    @State private var working = false
    @State private var signInTask: Task<Void, Never>?

    private enum Stage { case confirm, signingIn, chooseRoot }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Đổi tài khoản Google?").font(.title3.weight(.semibold))
            switch stage {
            case .confirm:
                Text("Trạng thái đích Drive sẽ được đặt lại. Nếu tài khoản mới đã có thư mục PhotoVault, ứng dụng khôi phục từ đó trước khi upload.")
                    .foregroundStyle(.secondary)
            case .signingIn:
                HStack { ProgressView().controlSize(.small); Text("Đang chờ trình duyệt…") }
            case .chooseRoot:
                Text("Đã đăng nhập: \(change?.identity.email ?? "tài khoản mới")").fontWeight(.medium)
                Text("Tài khoản mới chỉ được dùng sau khi bạn bấm Áp dụng. Trong lúc chọn, đích Drive tạm dừng.")
                    .font(.caption).foregroundStyle(.secondary)
                RootChooser(roots: roots, canReuse: model.hardeningAvailable, reuseRootId: $reuseRootId, newName: $newName)
            }
            NoticeBanner()
            HStack {
                Spacer()
                Button("Huỷ") { Task { await cancel() } }.keyboardShortcut(.cancelAction)
                switch stage {
                case .confirm: Button("Tiếp tục") { signInTask = Task { await signIn() } }.keyboardShortcut(.defaultAction)
                case .signingIn: EmptyView()
                case .chooseRoot:
                    Button("Áp dụng") { Task { await apply() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || (reuseRootId == nil && RootNameValidator.validate(newName) != nil))
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onDisappear { Task { await cancel(dismissing: false) } }
    }

    private func signIn() async {
        stage = .signingIn
        do {
            let result = try await model.beginAccountChange()
            if result.staged == nil {
                model.showNotice("Vẫn là tài khoản cũ nên đích Drive chạy tiếp.")
                dismiss()
                return
            }
            change = result
            let found = try await model.driveRoots(for: result)
            roots = found.map { .init(id: $0.remoteId, name: $0.name) }
            reuseRootId = canReuseFirst(found)
            newName = model.driveRecord?.config.driveRootName ?? "Camera Uploads"
            stage = .chooseRoot
        } catch {
            if !(error is CancellationError), !Task.isCancelled { model.showError(error) }
            if let change { await model.cancelAccountChange(change) }
            change = nil
            stage = .confirm
        }
    }

    /// Stops a sign-in still waiting for the browser; a stage that arrives anyway is discarded by the model.
    private func cancel(dismissing: Bool = true) async {
        signInTask?.cancel()
        signInTask = nil
        if let change { await model.cancelAccountChange(change) }
        change = nil
        if dismissing { dismiss() }
    }

    private func canReuseFirst(_ found: [RemoteItem]) -> String? {
        model.hardeningAvailable ? found.first?.remoteId : nil
    }

    private func apply() async {
        working = true
        defer { working = false }
        let choice: RootChoice
        if let id = reuseRootId, let root = roots.first(where: { $0.id == id }) {
            choice = .reuse(rootId: id, name: root.name)
        } else {
            choice = .createNew(name: newName)
        }
        do {
            guard let change else { return }
            try await model.applyAccountChange(change, choice: choice)
            self.change = nil
            dismiss()
        } catch {
            // The model discarded the stage and kept the old account, so the owner starts over.
            model.showError(error)
            self.change = nil
            stage = .confirm
        }
    }
}

/// FR-08: move Drive backups to a different root folder of the same account.
struct RootChangeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var roots: [RootChooser.RemoteItemSummary] = []
    @State private var reuseRootId: String?
    @State private var newName = "Camera Uploads"
    @State private var loaded = false
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Đổi thư mục gốc?").font(.title3.weight(.semibold))
            Text("Trạng thái đích Drive sẽ được đặt lại. Thư mục cũ giữ nguyên. Nếu thư mục mới đã có dữ liệu PhotoVault, ứng dụng khôi phục trước khi upload.")
                .foregroundStyle(.secondary)
            if loaded {
                RootChooser(roots: roots, canReuse: model.hardeningAvailable, reuseRootId: $reuseRootId, newName: $newName)
            } else {
                ProgressView().controlSize(.small)
            }
            NoticeBanner()
            HStack {
                Spacer()
                Button("Huỷ") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Áp dụng") { Task { await apply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!loaded || working || (reuseRootId == nil && RootNameValidator.validate(newName) != nil))
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            do {
                let currentId = model.driveRecord?.config.driveRootId
                roots = try await model.driveRoots().filter { $0.remoteId != currentId }.map { .init(id: $0.remoteId, name: $0.name) }
            } catch {
                model.showError(error)
            }
            loaded = true
        }
    }

    private func apply() async {
        working = true
        defer { working = false }
        let choice: RootChoice
        if let id = reuseRootId, let root = roots.first(where: { $0.id == id }) {
            choice = .reuse(rootId: id, name: root.name)
        } else {
            choice = .createNew(name: newName)
        }
        do {
            try await model.applyDriveRoot(choice, identity: nil)
            dismiss()
        } catch {
            model.showError(error)
        }
    }
}
