import PhotoVaultAppSupport
import SwiftUI

extension StatusTone {
    var color: Color {
        switch self {
        case .green: .green
        case .orange: .orange
        case .red: .red
        case .gray: .secondary
        }
    }
}

extension OverallTone {
    var color: Color {
        switch self {
        case .ok: .green
        case .orange: .orange
        case .red: .red
        }
    }
}

/// Status is a dot plus text; colour is never the only signal.
struct StatusDot: View {
    var color: Color

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
    }
}

enum BannerStyle {
    case info, warning, danger, success

    var color: Color {
        switch self {
        case .info: .accentColor
        case .warning: .orange
        case .danger: .red
        case .success: .green
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        case .success: "checkmark.circle.fill"
        }
    }
}

/// A callout: title, explanation and action buttons, like the alert cards in the mockups.
struct Banner<Actions: View>: View {
    var style: BannerStyle
    var title: String
    var message: String?
    @ViewBuilder var actions: () -> Actions

    init(_ style: BannerStyle, title: String, message: String? = nil, @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.style = style
        self.title = title
        self.message = message
        self.actions = actions
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: style.symbol).foregroundStyle(style.color).font(.title3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                actions().controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(style.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(style.color.opacity(0.35)))
        .accessibilityElement(children: .contain)
    }
}

/// A transient message the model raised (success or failure).
struct NoticeBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let notice = model.notice {
            HStack(spacing: 8) {
                Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(notice.isError ? .red : .green)
                Text(notice.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { model.notice = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Đóng thông báo")
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .task(id: notice.id) {
                try? await Task.sleep(for: .seconds(notice.isError ? 12 : 6))
                if model.notice?.id == notice.id { model.notice = nil }
            }
        }
    }
}

/// A labelled row of a settings form: title with optional detail on the left, control on the right.
struct FormRow<Control: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var control: () -> Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
    }
}

struct ProgressBar: View {
    var fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        ProgressView(value: min(1, max(0, fraction))).tint(tint).progressViewStyle(.linear)
    }
}
