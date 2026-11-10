import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultAppSupport
@testable import PhotoVaultEngine

struct CardActivityTextTests {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private let gib: Int64 = 1 << 30

    private func vi<T>(_ body: () -> T) -> T { L10n.$override.withValue(.vi, operation: body) }
    private func en<T>(_ body: () -> T) -> T { L10n.$override.withValue(.en, operation: body) }

    private func snapshot(
        overall: EngineSnapshot.Overall = .syncing, done: Int = 10, total: Int = 100, destinations: [DestinationSnapshot] = [],
        nextRetryAt: Date? = nil
    ) -> EngineSnapshot {
        var snapshot = EngineSnapshot(
            overall: overall, scanState: .complete, destinations: destinations, backfillDoneAssets: done, backfillTotalAssets: total,
            bytesUploaded: 0, etaSeconds: nil, pending: 5, deferred: 0, skipped: 0, missingRemote: 0, updatedAt: t0)
        snapshot.nextRetryAt = nextRetryAt
        return snapshot
    }

    private func transfer(
        _ kind: TransferKind = .upload, source: SourceID = .photos, to destination: String? = "Google Drive", account: String? = "ten@example.com",
        done: Int64 = gib_, total: Int64? = 2 * gib_, ago: TimeInterval = 5
    ) -> TransferProgress {
        TransferProgress(
            kind: kind, fileName: "IMG_1234.MOV", destinationName: destination, accountEmail: account, sourceId: source,
            bytesDone: done, bytesTotal: total, startedAt: Date(timeIntervalSince1970: 1_793_000_000 - ago))
    }

    private func destination(_ name: String, _ status: DestinationStatus) -> DestinationSnapshot {
        DestinationSnapshot(id: .googleDrive, displayName: name, status: status, pending: 1, deferred: 0, skipped: 0, missingRemote: 0, lastSuccessAt: nil)
    }

    private func backfill(
        _ snapshot: EngineSnapshot, _ transfers: [TransferProgress] = [], disk: MacDiskState = .ok
    ) -> CardActivity {
        CardActivityText.backfill(snapshot: snapshot, transfers: transfers, now: t0, disk: disk, settings: GlobalSettings())
    }

    // MARK: Backfill card

    @Test func theBackfillCardShowsTheFullTransferLineOfPhotosFiles() {
        let activity = vi { backfill(snapshot(), [transfer()]) }
        #expect(activity == .transfer("Đang upload IMG_1234.MOV lên Google Drive (ten@example.com) · 1,0 / 2,0 GB (50%)"))
        #expect(en { backfill(snapshot(), [transfer()]) } == .transfer("Uploading IMG_1234.MOV to Google Drive (ten@example.com) · 1.0 / 2.0 GB (50%)"))
    }

    @Test func importFilesAreNotTheBackfillsCurrentFile() {
        let other = SourceID.folder()
        let activity = vi { backfill(snapshot(), [transfer(source: other)]) }
        #expect(activity == .preparing("Đang chuẩn bị file tiếp theo…"))
    }

    @Test func aTransferThatHasNotRunASecondYetDoesNotCountAndTheCardSaysItIsPreparing() {
        #expect(vi { backfill(snapshot(), [transfer(ago: 0.3)]) } == .preparing("Đang chuẩn bị file tiếp theo…"))
        #expect(en { backfill(snapshot(), []) } == .preparing("Preparing the next file…"))
    }

    @Test func waitingReasonsExplainWhyNothingMoves() {
        #expect(vi { backfill(snapshot(overall: .paused)) } == .waiting("Đã tạm dừng · bấm Tiếp tục tất cả"))
        #expect(vi { backfill(snapshot(overall: .offline)) } == .waiting("Chờ có mạng"))
        #expect(en { backfill(snapshot(overall: .offline)) } == .waiting("Waiting for the network"))
        #expect(vi { backfill(snapshot(overall: .photosUnauthorized)) } == .waiting("Chưa có quyền Photos"))
        let low = vi { backfill(snapshot(), disk: .low) }
        guard case .waiting(let lowText) = low else { Issue.record("low disk must wait: \(low)"); return }
        #expect(lowText.hasPrefix("Ổ Mac gần đầy · backfill chờ trống từ "))
        guard case .waiting(let criticalText) = vi({ backfill(snapshot(), disk: .critical) }) else { Issue.record("critical disk must wait"); return }
        #expect(criticalText.hasPrefix("Ổ Mac gần đầy"))
        let away = snapshot(destinations: [destination("NAS", .unavailable(.offline))])
        #expect(vi { backfill(away) } == .waiting("NAS không khả dụng · chờ kết nối lại"))
        let retry = snapshot(nextRetryAt: t0.addingTimeInterval(125))
        #expect(vi { backfill(retry) } == .waiting("Chờ thử lại sau 2:05"))
        #expect(en { backfill(retry) } == .waiting("Retrying in 2:05"))
        let due = snapshot(nextRetryAt: t0.addingTimeInterval(-5))
        #expect(vi { backfill(due) } == .preparing("Đang chuẩn bị file tiếp theo…"))
    }

    @Test func aRunningTransferWinsOverAnyWaitingReason() {
        let retry = snapshot(nextRetryAt: t0.addingTimeInterval(125))
        if case .transfer = vi({ backfill(retry, [transfer()]) }) {} else { Issue.record("a moving file is not waiting") }
    }

    // MARK: Import card

    @Test func theImportCardShowsOnlyItsOwnTransfers() {
        let mine = SourceID.folder(), other = SourceID.folder()
        let download = transfer(.download(.dropbox), source: mine, to: nil, account: "ten@example.com")
        #expect(vi { CardActivityText.importJob(mine, transfers: [transfer(source: other), download], now: t0) }
            == "Đang tải IMG_1234.MOV từ Dropbox (ten@example.com) · 1,0 / 2,0 GB (50%)")
        #expect(CardActivityText.importJob(mine, transfers: [transfer(source: other)], now: t0) == nil)
        #expect(CardActivityText.importJob(mine, transfers: [], now: t0) == nil)
    }

    // MARK: Header

    @Test func theHeaderUsesTheShortLineWhileACardShowsTheFullOne() {
        let upload = transfer()
        let backfilling = snapshot(done: 10, total: 100)
        let header = vi { OverallStatusText.make(snapshot: backfilling, disk: .ok, settings: GlobalSettings(), now: t0, transfers: [upload]) }
        #expect(header.title == "Đang backfill")
        #expect(header.subtitle == "Đang upload IMG_1234.MOV · 50%")
        let idle = snapshot(done: 0, total: 0)
        let plain = vi { OverallStatusText.make(snapshot: idle, disk: .ok, settings: GlobalSettings(), now: t0, transfers: [upload]) }
        #expect(plain.subtitle == "Đang upload IMG_1234.MOV lên Google Drive (ten@example.com) · 1,0 / 2,0 GB (50%)")
        var importing = idle
        importing.imports = [ImportSnapshot(id: .folder(), displayName: "Trip", status: .importing, createdAt: t0)]
        let shortToo = vi { OverallStatusText.make(snapshot: importing, disk: .ok, settings: GlobalSettings(), now: t0, transfers: [upload]) }
        #expect(shortToo.subtitle == "Đang upload IMG_1234.MOV · 50%")
    }

    @Test func theShortLineKeepsTheOtherFilesCountAndDropsDetail() {
        let a = transfer(ago: 60), b = transfer(.copy, to: "NAS", account: nil, ago: 30)
        let short = vi { TransferLineText.make([a, b], now: t0, style: .short) }
        #expect(short == "Đang upload IMG_1234.MOV · 50% · +1 file khác")
        let unknown = transfer(.download(.dropbox), to: nil, done: 500 << 20, total: nil, ago: 90)
        #expect(vi { TransferLineText.make([unknown], now: t0, style: .short) } == "Đang tải IMG_1234.MOV từ Dropbox")
    }
}

private let gib_: Int64 = 1 << 30
