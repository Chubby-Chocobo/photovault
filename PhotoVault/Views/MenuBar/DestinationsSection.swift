import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultEngine
import SwiftUI

struct DestinationsSection: View {
    @Environment(AppModel.self) private var model
    var snapshot: EngineSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Đích").font(.subheadline.weight(.semibold))
                Spacer()
                Text("8.9.2").font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(snapshot.destinations, id: \.id) { destination in
                DestinationRow(destination: destination, record: model.destinations.first { $0.id == destination.id })
            }
        }
    }
}

private struct DestinationRow: View {
    @Environment(AppModel.self) private var model
    var destination: DestinationSnapshot
    var record: DestinationRecord?

    var body: some View {
        let status = StatusText.presentation(for: destination.status)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: destination.id.kind == .googleDrive ? "icloud" : "externaldrive")
                .frame(width: 20).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.displayName).font(.callout.weight(.medium))
                HStack(spacing: 5) {
                    StatusDot(color: status.tone.color)
                    Text(status.label).font(.caption)
                    Text(status.code).font(.caption2).foregroundStyle(.tertiary)
                }
                Text("Chờ \(VietnameseFormat.integer(destination.pending)) · Lần thành công cuối: \(RelativeTimeText.ago(destination.lastSuccessAt, now: Date()))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let record, record.kind == .localFolder {
                Button { model.revealInFinder(record) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .disabled(destination.status.reason == .offline)
                    .help("Mở trong Finder")
                    .accessibilityLabel("Mở \(destination.displayName) trong Finder")
            }
            if let record {
                let paused = model.isOwnerPaused(record)
                Button { model.togglePause(record) } label: { Image(systemName: paused ? "play.fill" : "pause.fill") }
                    .buttonStyle(.borderless)
                    .help(paused ? "Tiếp tục" : "Tạm dừng")
                    .accessibilityLabel((paused ? "Tiếp tục " : "Tạm dừng ") + destination.displayName)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
