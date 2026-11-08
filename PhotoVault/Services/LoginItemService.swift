import Foundation
import ServiceManagement

/// FR-62: "Mở khi đăng nhập" through `SMAppService.mainApp`.
enum LoginItemService {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// True when macOS wants the owner to approve the item in System Settings › Login Items.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled { try service.register() }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
    }
}
