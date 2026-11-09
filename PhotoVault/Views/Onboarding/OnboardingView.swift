import PhotoVaultAppSupport
import SwiftUI
import PhotoVaultCore

/// The first-run wizard (FR-01), 720 × 560 like the onboarding mockup.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @State private var model: OnboardingModel?

    var body: some View {
        Group {
            if let model {
                OnboardingContent(model: model)
                    .navigationTitle(tr(vi: "Chào mừng đến PhotoVault", en: "Welcome to PhotoVault"))
                    .id(app.language)
            } else {
                ProgressView().frame(width: 720, height: 560)
            }
        }
        .onAppear { if model == nil { model = OnboardingModel(app: app) } }
    }
}

private struct OnboardingContent: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        NoticeBanner()
                        stepContent
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                bottomBar
            }
        }
        .frame(width: 720, height: 560)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text("PhotoVault").font(.headline)
                    Text(tr(vi: "Thiết lập lần đầu", en: "First-time setup")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 12)
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                Button { model.jump(to: step) } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle().fill(step < model.progress.furthest ? Color.accentColor : Color.clear)
                                .overlay(Circle().stroke(.secondary.opacity(0.5)))
                            if step < model.progress.furthest {
                                Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white)
                            } else {
                                Text("\(step.rawValue)").font(.caption2)
                            }
                        }
                        .frame(width: 20, height: 20)
                        Text(step.title).fontWeight(step == model.step ? .semibold : .regular)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canJump(to: step) && step != model.step)
                .accessibilityAddTraits(step == model.step ? .isSelected : [])
            }
            Spacer()
            InterfaceLanguagePicker().labelsHidden().controlSize(.small)
        }
        .padding(16)
        .frame(width: 210)
        .background(.quaternary.opacity(0.4))
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .googleSignIn: GoogleStep(model: model)
        case .photosPermission: PhotosStep(model: model)
        case .driveRoot: DriveRootStep(model: model)
        case .archiveTimeZone: TimeZoneStep(model: model)
        case .syncMode: SyncModeStep(model: model)
        case .notifications: NotificationsStep(model: model)
        case .nas: NasStep(model: model)
        case .summary: SummaryStep(model: model)
        case .start: StartStep(model: model)
        }
    }

    private var bottomBar: some View {
        HStack {
            Text(tr(vi: "Bước \(model.step.rawValue) / 9", en: "Step \(model.step.rawValue) of 9")).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if model.step.rawValue > 1 && !model.started { Button(tr(vi: "Quay lại", en: "Back")) { model.back() } }
            if model.canSkip { Button(tr(vi: "Bỏ qua", en: "Skip")) { model.advance() } }
            if model.step != .start && !model.canSkip {
                Button(tr(vi: "Tiếp tục", en: "Continue")) { model.advance() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!model.canAdvance)
            }
            if model.step == .start && !model.started {
                Button(tr(vi: "Bắt đầu", en: "Start")) { Task { await model.start() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }
}

/// Heading and lead paragraph shared by every step.
struct StepHeader: View {
    var title: String
    var lead: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.semibold))
            Text(lead).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
