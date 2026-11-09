import PhotoVaultAppSupport
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
        SettingsSection("Ứng dụng") {
            Toggle("Mở khi đăng nhập", isOn: model.binding(\.launchAtLogin))
            FormRow("Thông báo", detail: "Mỗi loại × mỗi đích tối đa 1 lần / 12 giờ") {
                Button("Mở System Settings…") { model.openSystemSettings(.notifications) }
            }
        }
        SettingsSection("Tài khoản Google") {
            FormRow(accountTitle, detail: "Quyền: drive.file · openid · email") {
                HStack {
                    if model.driveNeedsSignIn {
                        Button("Đăng nhập lại…") { sheet = .signInAgain }
                        Button("Đổi tài khoản…") { sheet = .changeAccount }
                    } else {
                        Button("Đổi tài khoản…") { sheet = .changeAccount }
                        Button("Đăng xuất…") { confirmSignOut = true }
                    }
                }
            }
            .disabled(model.driveRecord == nil)
            Divider()
            FormRow("Thư mục gốc") {
                HStack {
                    TextField("Tên thư mục gốc", text: $rootName).textFieldStyle(.roundedBorder).frame(width: 220)
                    Button("Đổi tên") { Task { await model.renameDriveRoot(to: rootName) } }
                        .disabled(rootName == savedRootName || RootNameValidator.validate(rootName) != nil)
                }
            }
            .disabled(model.driveRecord?.config.driveRootId == nil)
            FormRow("Đổi sang thư mục khác sẽ đặt lại trạng thái đích Drive và khôi phục từ thư mục mới nếu nó đã có dữ liệu.") {
                Button("Đổi thư mục gốc…") { sheet = .changeRoot }
            }
            .disabled(model.driveRecord == nil)
        }
        SettingsSection("Ngày giờ") {
            FormRow("Archive timezone") {
                Picker("Archive timezone", selection: timeZoneBinding) {
                    ForEach(ArchiveTimeZoneText.options(including: model.archiveTimeZone), id: \.identifier) { zone in
                        Text(ArchiveTimeZoneText.label(zone)).tag(zone.identifier)
                    }
                }
                .labelsHidden().frame(width: 280)
            }
            SettingsNote("Đổi múi giờ chỉ áp dụng cho ảnh chưa được xếp chỗ. Ảnh đã backup giữ nguyên ngày và tên.")
        }
        .onAppear { rootName = savedRootName }
        .onChange(of: savedRootName) { _, new in rootName = new }
        .confirmationDialog("Đăng xuất Google?", isPresented: $confirmSignOut) {
            Button("Đăng xuất") { Task { await model.signOutGoogle() } }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("Thu hồi quyền và xoá token khỏi Keychain. Lịch sử backup trong cơ sở dữ liệu giữ nguyên. Đăng nhập lại bằng tài khoản khác được tính là đổi tài khoản.")
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
        guard let email = model.accountEmail else { return "Chưa đăng nhập" }
        return model.driveNeedsSignIn ? "\(email) — cần đăng nhập lại" : email
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
