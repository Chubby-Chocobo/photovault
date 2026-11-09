import Foundation

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, content, organization, places, destinations, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "Chung"
        case .content: "Nội dung"
        case .organization: "Sắp xếp"
        case .places: "Địa danh & riêng tư"
        case .destinations: "Đích"
        case .advanced: "Nâng cao"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .content: "photo.on.rectangle"
        case .organization: "folder.badge.gearshape"
        case .places: "mappin.and.ellipse"
        case .destinations: "externaldrive.connected.to.line.below"
        case .advanced: "slider.horizontal.3"
        }
    }
}

/// A window some part of the app wants on screen. `MenuBarLabel` owns the SwiftUI environment actions
/// that open scenes, so everything else asks through the model.
enum WindowRequest: Equatable {
    case onboarding
    case activity
    case settings(SettingsTab)
}
