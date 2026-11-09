import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultEngine
import SwiftUI

/// The `MenuBarExtra` popover (FR-60), 360 pt wide as in the menu-bar mockup.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.phase {
            case .launching:
                ProgressView("Đang khởi động…").frame(maxWidth: .infinity)
            case .needsOnboarding:
                OnboardingPrompt()
            case .running:
                RunningContent()
            }
            Divider()
            MenuBarActions()
        }
        .padding(12)
        .frame(width: 360)
        .task { await model.refreshSnapshot() }
    }
}

private struct OnboardingPrompt: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chào mừng đến PhotoVault").font(.headline)
            Text("Hoàn tất thiết lập lần đầu để bắt đầu backup ảnh.").font(.callout).foregroundStyle(.secondary)
            Button("Mở thiết lập…") { model.open(.onboarding) }.buttonStyle(.borderedProminent)
        }
    }
}

private struct RunningContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            OverallHeader()
            NoticeBanner()
            ForEach(model.visibleDecisions) { DecisionCard(decision: $0) }
            if model.diskState == .critical { DiskCriticalCard() }
            if model.driveNeedsSignIn { SignInAgainCard() }
            ForEach(model.localRecords.filter { $0.status == .unavailable(.offline) }) { OfflineCard(record: $0) }
            if model.photosAuthorization != .authorized && model.photosAuthorization != .notDetermined { PhotosDeniedCard() }
            if let snapshot = model.snapshot {
                BackfillSection(snapshot: snapshot)
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
                Text(presentation.title).font(.headline)
                Text(presentation.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Sync now") { model.syncNow() }
                .buttonStyle(.borderedProminent)
                .disabled(model.isPausedAll || model.snapshot?.overall == .photosUnauthorized)
        }
        .accessibilityElement(children: .combine)
    }

    private var overall: OverallPresentation {
        guard let snapshot = model.snapshot else {
            return OverallPresentation(title: "Đang kiểm tra…", subtitle: "", tone: .ok, isWorking: false)
        }
        return OverallStatusText.make(snapshot: snapshot, disk: model.diskState, settings: model.persistedSettings, now: Date())
    }
}

private struct BackfillSection: View {
    var snapshot: EngineSnapshot

    var body: some View {
        if snapshot.backfillTotalAssets > 0 {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Backfill").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(VietnameseFormat.integer(snapshot.backfillDoneAssets)) / \(VietnameseFormat.integer(snapshot.backfillTotalAssets)) asset")
                        .font(.caption).monospacedDigit()
                }
                ProgressBar(fraction: ProgressText.fraction(done: snapshot.backfillDoneAssets, total: snapshot.backfillTotalAssets))
                    .accessibilityLabel("Tiến độ backfill")
                HStack {
                    Text("Đã upload \(VietnameseFormat.bytes(snapshot.bytesUploaded))")
                    Spacer()
                    if snapshot.backfillDoneAssets < snapshot.backfillTotalAssets { Text(ProgressText.eta(seconds: snapshot.etaSeconds)) }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let caption = ProgressText.rateCaption(
                    remainingAssets: snapshot.backfillTotalAssets - snapshot.backfillDoneAssets, etaSeconds: snapshot.etaSeconds) {
                    Text(caption).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

private struct CountersSection: View {
    var snapshot: EngineSnapshot

    var body: some View {
        HStack {
            counter(snapshot.pending, "Chờ", "pending")
            counter(snapshot.deferred, "Hoãn", "deferred")
            counter(snapshot.skipped, "Bỏ qua", "skipped")
            counter(snapshot.missingRemote, "Thiếu ở đích", "missingRemote", alert: true)
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
