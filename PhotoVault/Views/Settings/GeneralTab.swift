import PhotoVaultAppSupport
import PhotoVaultCore
import SwiftUI

/// Settings › Chung: launch at login (FR-62), notifications, account and root (FR-08), archive timezone (FR-07).
struct GeneralTab: View {
    @Environment(AppModel.self) private var model
    @State private var rootName = ""
    @State private var sheet: Sheet?
    @State private var confirmSignOut = false

    private enum Sheet: String, Identifiable {
        case changeAccount, signInAgain, changeRoot
        var id: String { rawValue }
    }

    var body: some View {
        SettingsSection(tr(vi: "Ứng dụng", en: "App")) {
            FormRow(tr(vi: "Ngôn ngữ giao diện", en: "Interface language"),
                    detail: tr(vi: "Đổi ngay. Hoạt động đã ghi giữ nguyên ngôn ngữ lúc ghi; tên thư mục trên đích không đổi.",
                               en: "Applies at once. Activity already recorded keeps its language; folder names on destinations don’t change.")) {
                InterfaceLanguagePicker().labelsHidden().frame(width: 190)
            }
            Toggle(tr(vi: "Mở khi đăng nhập", en: "Open at login"), isOn: model.binding(\.launchAtLogin))
            FormRow(tr(vi: "Thông báo", en: "Notifications"), detail: tr(vi: "Mỗi loại × mỗi đích tối đa 1 lần / 12 giờ", en: "Each kind, per destination, at most once every 12 hours")) {
                Button(tr(vi: "Mở System Settings…", en: "Open System Settings…")) { model.openSystemSettings(.notifications) }
            }
        }
        SettingsSection(tr(vi: "Tài khoản Google", en: "Google account")) {
            FormRow(accountTitle, detail: tr(vi: "Quyền: drive.file · openid · email", en: "Permissions: drive.file · openid · email")) {
                HStack {
                    if model.driveNeedsSignIn {
                        Button(tr(vi: "Đăng nhập lại…", en: "Sign in again…")) { sheet = .signInAgain }
                        Button(tr(vi: "Đổi tài khoản…", en: "Change account…")) { sheet = .changeAccount }
                    } else {
                        Button(tr(vi: "Đổi tài khoản…", en: "Change account…")) { sheet = .changeAccount }
                        Button(tr(vi: "Đăng xuất…", en: "Sign out…")) { confirmSignOut = true }
                    }
                }
            }
            .disabled(model.driveRecord == nil)
            Divider()
            FormRow(tr(vi: "Thư mục gốc", en: "Root folder")) {
                HStack {
                    TextField(tr(vi: "Tên thư mục gốc", en: "Root folder name"), text: $rootName).textFieldStyle(.roundedBorder).frame(width: 220)
                    Button(tr(vi: "Đổi tên", en: "Rename")) { Task { await model.renameDriveRoot(to: rootName) } }
                        .disabled(rootName == savedRootName || RootNameValidator.validate(rootName) != nil)
                }
            }
            .disabled(model.driveRecord?.config.driveRootId == nil)
            FormRow(tr(vi: "Đổi sang thư mục khác sẽ đặt lại trạng thái đích Drive và khôi phục từ thư mục mới nếu nó đã có dữ liệu.", en: "Switching to another folder resets the Drive destination's state and restores from the new folder if it already has data.")) {
                Button(tr(vi: "Đổi thư mục gốc…", en: "Change root folder…")) { sheet = .changeRoot }
            }
            .disabled(model.driveRecord == nil)
        }
        SettingsSection(tr(vi: "Ngày giờ", en: "Date and time")) {
            FormRow("Archive timezone") {
                Picker("Archive timezone", selection: timeZoneBinding) {
                    ForEach(ArchiveTimeZoneText.options(including: model.archiveTimeZone), id: \.identifier) { zone in
                        Text(ArchiveTimeZoneText.label(zone)).tag(zone.identifier)
                    }
                }
                .labelsHidden().frame(width: 280)
            }
            SettingsNote(tr(vi: "Đổi múi giờ chỉ áp dụng cho ảnh chưa được xếp chỗ. Ảnh đã backup giữ nguyên ngày và tên.", en: "A new timezone only applies to photos not yet placed. Photos already backed up keep their date and name."))
        }
        .onAppear { rootName = savedRootName }
        .onChange(of: savedRootName) { _, new in rootName = new }
        .confirmationDialog(tr(vi: "Đăng xuất Google?", en: "Sign out of Google?"), isPresented: $confirmSignOut) {
            Button(tr(vi: "Đăng xuất", en: "Sign out")) { Task { await model.signOutGoogle() } }
            Button(tr(vi: "Huỷ", en: "Cancel"), role: .cancel) {}
        } message: {
            Text(tr(vi: "Thu hồi quyền và xoá token khỏi Keychain. Lịch sử backup trong cơ sở dữ liệu giữ nguyên. Đăng nhập lại bằng tài khoản khác được tính là đổi tài khoản.", en: "Revokes access and removes the token from the Keychain. Backup history in the database is kept. Signing in again with a different account counts as changing account."))
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .changeAccount: AccountChangeSheet()
            case .signInAgain: AccountChangeSheet(reauth: true)
            case .changeRoot: RootChangeSheet()
            }
        }
    }

    private var accountTitle: String {
        guard let email = model.accountEmail else { return tr(vi: "Chưa đăng nhập", en: "Not signed in") }
        return model.driveNeedsSignIn ? tr(vi: "\(email) — cần đăng nhập lại", en: "\(email) — sign in again needed") : email
    }

    private var savedRootName: String { model.driveRecord?.config.driveRootName ?? "" }

    private var timeZoneBinding: Binding<String> {
        Binding(
            get: { model.archiveTimeZone.identifier },
            set: { id in
                guard let zone = TimeZone(identifier: id) else { return }
                Task { await model.setArchiveTimeZone(zone) }
            })
    }
}
