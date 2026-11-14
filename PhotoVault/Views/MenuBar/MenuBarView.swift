import AppKit
import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultEngine
import SwiftUI

/// The `MenuBarExtra` popover (FR-60), 360 pt wide as in the menu-bar mockup. While the engine runs, its
/// content area is as tall as its content, up to what the screen can hold, and scrolls past that. While the
/// popup is open that area only grows (`PopoverContentHeight`), so the action rows below never move up and
/// back down; each time the popup opens it fits its content again.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @State private var contentHeight = PopoverContentHeight()
    @State private var actionsHeight: Double = 0
    /// The visible height of the popup's screen, once its window has said which screen that is.
    @State private var screenHeight: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.phase {
            case .launching:
                ProgressView(tr(vi: "Đang khởi động…", en: "Starting…")).frame(maxWidth: .infinity)
            case .needsOnboarding:
                OnboardingPrompt()
            case .running:
                ScrollView {
                    RunningContent()
                        .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { contentHeight.measured($0) }
                }
                .frame(height: contentHeight.height(limit: contentLimit).map { CGFloat($0) })
            }
            Divider()
            MenuBarActions()
                .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { actionsHeight = $0 }
        }
        .id(model.language)
        .padding(12)
        .frame(width: PopoverLayout.width)
        .background(PopupWindowObserver(
            onOpenChange: { isOpen in
                isOpen ? contentHeight.opened() : contentHeight.closed()
                model.popupOpen = isOpen
            },
            onScreenHeight: { height in if screenHeight != height { screenHeight = height } }))
        .task { await model.refreshSnapshot() }
    }

    private var contentLimit: Double {
        PopoverLayout.contentLimit(
            visibleScreenHeight: screenHeight ?? Double(NSScreen.main?.visibleFrame.height ?? 800), actionsHeight: actionsHeight)
    }
}

private struct OnboardingPrompt: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr(vi: "Chào mừng đến PhotoVault", en: "Welcome to PhotoVault")).font(.headline)
                Spacer(minLength: 0)
                LanguageMenu()
            }
            Text(tr(vi: "Hoàn tất thiết lập lần đầu để bắt đầu backup ảnh.", en: "Finish the first-time setup to start backing up photos.")).font(.callout).foregroundStyle(.secondary)
            Button(tr(vi: "Mở thiết lập…", en: "Open setup…")) { model.open(.onboarding) }.buttonStyle(.borderedProminent)
        }
    }
}

private struct RunningContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            OverallHeader()
            NoticeBanner()
            if model.snapshot?.overall == .legacyLayout { OldLayoutCard() }
            ForEach(model.visibleDecisions) { DecisionCard(decision: $0) }
            if model.diskState == .critical { DiskCriticalCard() }
            if model.driveNeedsSignIn { SignInAgainCard() }
            ForEach(model.localRecords.filter { $0.status == .unavailable(.offline) }) { OfflineCard(record: $0) }
            if model.photosAuthorization != .authorized && model.photosAuthorization != .notDetermined { PhotosDeniedCard() }
            if let snapshot = model.snapshot {
                BackfillSection(snapshot: snapshot)
                ImportsCard()
                DestinationsSection(snapshot: snapshot)
                CountersSection(snapshot: snapshot)
            }
        }
    }
}

private struct OverallHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let presentation = overall
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle().fill(presentation.tone.color.opacity(0.18)).frame(width: 34, height: 34)
                Image(systemName: presentation.isWorking ? "arrow.triangle.2.circlepath" : "photo.on.rectangle.angled")
                    .foregroundStyle(presentation.tone.color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(presentation.title).font(.headline).lineLimit(1).truncationMode(.tail).help(presentation.title)
                FittedLineText(line: presentation.subtitleLine).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            LanguageMenu()
            Button("Sync now") { model.syncNow() }
                .buttonStyle(.borderedProminent)
                .disabled(model.isPausedAll || model.snapshot?.overall == .photosUnauthorized || model.snapshot?.overall == .legacyLayout)
        }
    }

    private var overall: OverallPresentation {
        guard let snapshot = model.snapshot else {
            return OverallPresentation(title: tr(vi: "Đang kiểm tra…", en: "Checking…"), subtitle: "", tone: .ok, isWorking: false)
        }
        // `transferNow` ticks while files move, which re-renders the line as a transfer passes its first second.
        _ = model.transferNow
        return OverallStatusText.make(
            snapshot: snapshot, disk: model.diskState, settings: model.persistedSettings, now: Date(), transfers: model.transfers)
    }
}

private struct BackfillSection: View {
    @Environment(AppModel.self) private var model
    var snapshot: EngineSnapshot

    private func activityLine(now: Date) -> some View {
        let activity = CardActivityText.backfill(
            snapshot: snapshot, transfers: model.transfers, now: now, disk: model.diskState, settings: model.persistedSettings)
        return CardActivityLine(line: activity.line, isBusy: activity.isBusy, isWaiting: !activity.isBusy)
    }

    var body: some View {
        if BackfillText.isRunning(snapshot) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Backfill").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(VietnameseFormat.integer(snapshot.backfillDoneAssets)) / \(VietnameseFormat.integer(snapshot.backfillTotalAssets)) "
                        + tr(vi: "asset", en: L10n.plural(snapshot.backfillTotalAssets, one: "asset", other: "assets")))
                        .font(.caption).monospacedDigit().lineLimit(1)
                }
                ProgressBar(fraction: ProgressText.fraction(done: snapshot.backfillDoneAssets, total: snapshot.backfillTotalAssets))
                    .accessibilityLabel(tr(vi: "Tiến độ backfill", en: "Backfill progress"))
                // `transferNow` ticks while files move; a retry countdown has nothing moving, so it brings its own
                // clock, which runs only while the popup shows it.
                let _ = model.transferNow
                if snapshot.nextRetryAt != nil, model.popupOpen {
                    TimelineView(.periodic(from: .now, by: 1)) { context in activityLine(now: context.date) }
                } else {
                    activityLine(now: Date())
                }
                HStack {
                    Text(tr(vi: "Đã upload \(VietnameseFormat.bytes(snapshot.bytesUploaded))", en: "Uploaded \(VietnameseFormat.bytes(snapshot.bytesUploaded))"))
                        .layoutPriority(1)
                    Spacer(minLength: 6)
                    Text(ProgressText.eta(seconds: snapshot.etaSeconds)).truncationMode(.middle)
                }
                .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                // The rate caption keeps its line while there is no rate to show yet.
                let caption = ProgressText.rateCaption(
                    remainingAssets: snapshot.backfillTotalAssets - snapshot.backfillDoneAssets, etaSeconds: snapshot.etaSeconds)
                FittedLineText(line: FittedLine(lead: caption ?? "")).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct CountersSection: View {
    var snapshot: EngineSnapshot

    var body: some View {
        HStack {
            counter(snapshot.pending, tr(vi: "Chờ", en: "Pending"), "pending")
            counter(snapshot.deferred, tr(vi: "Hoãn", en: "Deferred"), "deferred")
            counter(snapshot.skipped, tr(vi: "Bỏ qua", en: "Skipped"), "skipped")
            counter(snapshot.missingRemote, tr(vi: "Thiếu ở đích", en: "Missing"), "missingRemote", alert: true)
        }
    }

    private func counter(_ value: Int, _ label: String, _ code: String, alert: Bool = false) -> some View {
        VStack(spacing: 1) {
            Text(VietnameseFormat.integer(value)).font(.title3.weight(.semibold)).monospacedDigit()
                .foregroundStyle(alert && value > 0 ? Color.red : Color.primary)
            Text(label).font(.caption)
            Text(code).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
