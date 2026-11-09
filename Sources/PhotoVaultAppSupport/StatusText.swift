import Foundation
import PhotoVaultCore

public enum StatusTone: String, Sendable, Equatable {
    case green, orange, red, gray
}

public struct StatusPresentation: Equatable, Sendable {
    public var label: String
    /// Raw enum 8.9.2 text for tooltips and logs, e.g. `paused(rootTrashed)`.
    public var code: String
    public var tone: StatusTone
    /// The owner has to decide something (FR-47); the UI shows the prompt card.
    public var needsOwnerDecision: Bool
}

/// Vietnamese text for destination status (spec 8.9.2) and the Mac disk guard.
public enum StatusText {
    public static func presentation(for status: DestinationStatus) -> StatusPresentation {
        let label = DestinationStatusText.label(status)
        let code = status.description
        switch status {
        case .active:
            return StatusPresentation(label: label, code: code, tone: .green, needsOwnerDecision: false)
        case .paused(.userPaused):
            return StatusPresentation(label: label, code: code, tone: .gray, needsOwnerDecision: false)
        case .paused(let reason):
            return StatusPresentation(
                label: label, code: code, tone: .orange,
                needsOwnerDecision: [.rootTrashed, .rootMissing, .folderTrashed].contains(reason))
        case .unavailable, .error:
            return StatusPresentation(label: label, code: code, tone: .red, needsOwnerDecision: false)
        }
    }

    public static func reasonText(_ reason: StatusReason) -> String { DestinationStatusText.reasonText(reason) }

    /// Label of the backup mode shown next to a destination.
    public static func scopeText(_ scope: ScopeMode) -> String {
        switch scope {
        case .full: tr(vi: "Toàn bộ thư viện", en: "Entire library")
        case .since(let day): tr(vi: "Từ ", en: "From ") + dayText(day)
        case .newOnly: tr(vi: "Chỉ ảnh mới", en: "New photos only")
        }
    }

    /// `2024-01-01` -> `01/01/2024`.
    public static func dayText(_ day: ArchiveDay) -> String {
        String(format: "%02d/%02d/%04d", day.day, day.month, day.year)
    }
}
