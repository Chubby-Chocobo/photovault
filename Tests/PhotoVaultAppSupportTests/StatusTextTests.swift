import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultAppSupport
@testable import PhotoVaultEngine

struct StatusTextTests {
    @Test func everyStatusHasLabelAndCode() {
        for reason in StatusReason.allCases {
            for status in [DestinationStatus.paused(reason), .unavailable(reason), .error(reason)] {
                let text = StatusText.presentation(for: status)
                #expect(!text.label.isEmpty)
                #expect(text.code == status.description)
            }
        }
    }

    @Test func activeIsGreen() {
        let text = StatusText.presentation(for: .active)
        #expect(text.label == "Đang hoạt động")
        #expect(text.tone == .green)
        #expect(!text.needsOwnerDecision)
    }

    @Test func ownerPauseIsGrayAndNeedsNoDecision() {
        let text = StatusText.presentation(for: .paused(.userPaused))
        #expect(text.label == "Tạm dừng (bởi bạn)")
        #expect(text.tone == .gray)
        #expect(!text.needsOwnerDecision)
    }

    @Test func trashedRootAsksTheOwner() {
        let text = StatusText.presentation(for: .paused(.rootTrashed))
        #expect(text.label == "Tạm dừng · thư mục gốc trong Thùng rác")
        #expect(text.tone == .orange)
        #expect(text.needsOwnerDecision)
        #expect(StatusText.presentation(for: .paused(.rootMissing)).needsOwnerDecision)
        #expect(StatusText.presentation(for: .paused(.folderTrashed)).needsOwnerDecision)
        #expect(!StatusText.presentation(for: .paused(.recovering)).needsOwnerDecision)
    }

    @Test func offlineIsRed() {
        let text = StatusText.presentation(for: .unavailable(.offline))
        #expect(text.label == "Không khả dụng · mất kết nối")
        #expect(text.tone == .red)
        #expect(text.code == "unavailable(offline)")
    }

    @Test func scopeText() {
        #expect(StatusText.scopeText(.full) == "Toàn bộ thư viện")
        #expect(StatusText.scopeText(.newOnly) == "Chỉ ảnh mới")
        #expect(StatusText.scopeText(.since(ArchiveDay(year: 2024, month: 1, day: 5)!)) == "Từ 05/01/2024")
    }
}

struct MacDiskStateTests {
    @Test func classifiesAgainstWatermarks() {
        let settings = GlobalSettings()
        let gib = GlobalSettings.GiB
        #expect(MacDiskState.classify(freeBytes: 3 * gib, settings: settings) == .critical)
        #expect(MacDiskState.classify(freeBytes: 12 * gib, settings: settings) == .low)
        #expect(MacDiskState.classify(freeBytes: 15 * gib, settings: settings) == .ok)
    }

    @Test func bytesToFreeFollowsLowWatermarkPlusFiveGB() {
        let settings = GlobalSettings()
        let gib = GlobalSettings.GiB
        #expect(MacDiskState.bytesToFree(freeBytes: 12 * gib, settings: settings) == 8 * gib)
        #expect(MacDiskState.bytesToFree(freeBytes: 2 * gib, settings: settings) == 18 * gib)
        #expect(MacDiskState.bytesToFree(freeBytes: 15 * gib, settings: settings) == nil)
        #expect(MacDiskState.bytesToFree(freeBytes: 80 * gib, settings: settings) == nil)
        #expect(MacDiskState.resumeBytes(settings: settings) == 20 * gib)
    }
}

struct OverallStatusTextTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let settings = GlobalSettings()

    private func destination(_ id: String, _ status: DestinationStatus, name: String = "Google Drive") -> DestinationSnapshot {
        DestinationSnapshot(
            id: DestinationID(rawValue: id)!, displayName: name, status: status, pending: 0, deferred: 0, skipped: 0,
            missingRemote: 0, lastSuccessAt: now.addingTimeInterval(-60))
    }

    private func snapshot(
        _ overall: EngineSnapshot.Overall = .idle, destinations: [DestinationSnapshot] = [], done: Int = 0, total: Int = 0
    ) -> EngineSnapshot {
        EngineSnapshot(
            overall: overall, scanState: .complete, destinations: destinations, backfillDoneAssets: done, backfillTotalAssets: total,
            bytesUploaded: 0, etaSeconds: nil, pending: 0, deferred: 0, skipped: 0, missingRemote: 0, updatedAt: now)
    }

    private func text(_ snapshot: EngineSnapshot, disk: MacDiskState = .ok) -> OverallPresentation {
        OverallStatusText.make(snapshot: snapshot, disk: disk, settings: settings, now: now)
    }

    @Test func pausedWinsOverEverything() {
        let result = text(snapshot(.paused, destinations: [destination("gdrive", .paused(.rootTrashed))]), disk: .critical)
        #expect(result.title == "Đã tạm dừng tất cả")
        #expect(result.tone == .orange)
    }

    @Test func ownerDecisionNamesTheDestinationAndOthers() {
        let local = DestinationID.local().rawValue
        let result = text(snapshot(destinations: [destination("gdrive", .paused(.rootTrashed)), destination(local, .active, name: "NAS")]))
        #expect(result.title == "Cần bạn quyết định")
        #expect(result.subtitle == "Google Drive đã tạm dừng · 1 đích khác vẫn chạy")
    }

    @Test func criticalDiskStopsExports() {
        let result = text(snapshot(destinations: [destination("gdrive", .active)]), disk: .critical)
        #expect(result.title == "Đã dừng export")
        #expect(result.tone == .red)
        #expect(result.subtitle.contains("20,0 GB"))
    }

    @Test func unavailableDestination() {
        let local = DestinationID.local().rawValue
        let result = text(snapshot(destinations: [destination("gdrive", .active), destination(local, .unavailable(.offline), name: "NAS")]))
        #expect(result.title == "NAS không khả dụng")
        #expect(result.subtitle == "1 đích khác vẫn chạy")
    }

    @Test func backfillAndIdle() {
        let active = [destination("gdrive", .active)]
        let backfill = text(snapshot(.syncing, destinations: active, done: 10, total: 100))
        #expect(backfill.title == "Đang backfill")
        #expect(backfill.isWorking)
        #expect(backfill.subtitle == "1 đích · sync lần cuối 1 phút trước")
        let idle = text(snapshot(.idle, destinations: active, done: 100, total: 100))
        #expect(idle.title == "Đã đồng bộ")
        #expect(!idle.isWorking)
        #expect(idle.tone == .ok)
    }

    @Test func oldLayoutBlocksEverythingElse() {
        let result = text(snapshot(.legacyLayout, destinations: [destination("gdrive", .paused(.rootTrashed))]), disk: .critical)
        #expect(result.title == "Cần bắt đầu lại")
        #expect(result.tone == .red)
        #expect(!result.isWorking)
    }

    @Test func blockedStates() {
        #expect(text(snapshot(.photosUnauthorized)).tone == .red)
        #expect(text(snapshot(.notBaselined)).title == "Chưa bắt đầu")
        #expect(text(snapshot(.offline)).title == "Không có mạng")
        #expect(text(snapshot(.needsReconciliation)).title == "Cần đối soát thư viện")
    }
}
