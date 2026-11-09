import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultDrive
import SwiftUI

/// FR-08: sign in with another account, then choose where its backups go. With `reauth`, the same
/// flow is offered as "sign in again": the same account simply resumes, another one is a change.
struct AccountChangeSheet: View {
    var reauth = false
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
            Text(reauth ? tr(vi: "Đăng nhập lại Google", en: "Sign in to Google again") : tr(vi: "Đổi tài khoản Google?", en: "Change Google account?")).font(.title3.weight(.semibold))
            switch stage {
            case .confirm:
                Text(reauth
                     ? tr(vi: "Đăng nhập lại bằng \(model.accountEmail ?? "tài khoản đang dùng") để backup chạy tiếp, không mất gì. Nếu chọn tài khoản khác, đó là đổi tài khoản: trạng thái đích Drive được đặt lại.",
                          en: "Sign in again with \(model.accountEmail ?? "the current account") so backups keep running; nothing is lost. Choosing a different account is a change of account: the Drive destination's state is reset.")
                     : tr(vi: "Nếu chọn tài khoản khác, trạng thái đích Drive sẽ được đặt lại; nếu tài khoản đó đã có thư mục PhotoVault, ứng dụng khôi phục từ đó trước khi upload. Chọn lại đúng tài khoản cũ thì chỉ là đăng nhập lại.",
                          en: "If you choose a different account, the Drive destination's state is reset; if that account already has a PhotoVault folder, the app restores from it before uploading. Choosing the same account again is just signing in again."))
                    .foregroundStyle(.secondary)
            case .signingIn:
                HStack { ProgressView().controlSize(.small); Text(tr(vi: "Đang chờ trình duyệt…", en: "Waiting for the browser…")) }
            case .chooseRoot:
                Text(tr(vi: "Đã đăng nhập: \(change?.identity.email ?? "tài khoản mới")", en: "Signed in: \(change?.identity.email ?? "new account")")).fontWeight(.medium)
                Text(tr(vi: "Tài khoản mới chỉ được dùng sau khi bạn bấm Áp dụng. Trong lúc chọn, đích Drive tạm dừng.", en: "The new account is used only after you click Apply. The Drive destination is paused while you choose."))
                    .font(.caption).foregroundStyle(.secondary)
                RootChooser(roots: roots, canReuse: model.hardeningAvailable, reuseRootId: $reuseRootId, newName: $newName)
            }
            NoticeBanner()
            HStack {
                Spacer()
                Button(tr(vi: "Huỷ", en: "Cancel")) { Task { await cancel() } }.keyboardShortcut(.cancelAction).disabled(working)
                switch stage {
                case .confirm: Button(tr(vi: "Tiếp tục", en: "Continue")) { signInTask = Task { await signIn() } }.keyboardShortcut(.defaultAction)
                case .signingIn: EmptyView()
                case .chooseRoot:
                    Button(tr(vi: "Áp dụng", en: "Apply")) { Task { await apply() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || (reuseRootId == nil && RootNameValidator.validate(newName) != nil))
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onDisappear { if !working { Task { await cancel(dismissing: false) } } }
    }

    private func signIn() async {
        stage = .signingIn
        do {
            let result = try await model.beginAccountChange()
            if result.staged == nil {
                model.showNotice(reauth ? tr(vi: "Đã đăng nhập lại, đích Drive chạy tiếp.", en: "Signed in again; the Drive destination resumes.") : tr(vi: "Vẫn là tài khoản cũ nên đích Drive chạy tiếp.", en: "Same account as before, so the Drive destination resumes."))
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
    /// Does nothing once Áp dụng has started: the engine finishes or fails the change by itself.
    private func cancel(dismissing: Bool = true) async {
        guard !working else { return }
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
            Text(tr(vi: "Đổi thư mục gốc?", en: "Change root folder?")).font(.title3.weight(.semibold))
            Text(tr(vi: "Trạng thái đích Drive sẽ được đặt lại. Thư mục cũ giữ nguyên. Nếu thư mục mới đã có dữ liệu PhotoVault, ứng dụng khôi phục trước khi upload.", en: "The Drive destination's state will be reset. The old folder is left as it is. If the new folder already has PhotoVault data, the app restores from it before uploading."))
                .foregroundStyle(.secondary)
            if loaded {
                RootChooser(roots: roots, canReuse: model.hardeningAvailable, reuseRootId: $reuseRootId, newName: $newName)
            } else {
                ProgressView().controlSize(.small)
            }
            NoticeBanner()
            HStack {
                Spacer()
                Button(tr(vi: "Huỷ", en: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr(vi: "Áp dụng", en: "Apply")) { Task { await apply() } }
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
