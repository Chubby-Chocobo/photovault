import Foundation
import PhotoVaultCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, content, organization, places, sources, destinations, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: tr(vi: "Chung", en: "General")
        case .content: tr(vi: "Nội dung", en: "Content")
        case .organization: tr(vi: "Sắp xếp", en: "Organization")
        case .places: tr(vi: "Địa danh & riêng tư", en: "Places & privacy")
        case .sources: tr(vi: "Nguồn", en: "Sources")
        case .destinations: tr(vi: "Đích", en: "Destinations")
        case .advanced: tr(vi: "Nâng cao", en: "Advanced")
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .content: "photo.on.rectangle"
        case .organization: "folder.badge.gearshape"
        case .places: "mappin.and.ellipse"
        case .sources: "tray.and.arrow.down"
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
    case log
    case settings(SettingsTab)
}
