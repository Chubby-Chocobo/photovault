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
        done: Int64 = gib_, total: Int64? = 2 * gib_, ago: TimeInterval = 5, backfill: Bool = true
    ) -> TransferProgress {
        var transfer = TransferProgress(
            kind: kind, fileName: "IMG_1234.MOV", destinationName: destination, accountEmail: account, sourceId: source,
            bytesDone: done, bytesTotal: total, startedAt: Date(timeIntervalSince1970: 1_793_000_000 - ago))
        transfer.isBackfill = backfill
        return transfer
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
        #expect(activity == .transfer(FittedLine(
            prefix: "Đang upload ", lead: "IMG_1234.MOV", place: " lên Google Drive (ten@example.com)", detail: " · 1,0 / 2,0 GB (50%)")))
        #expect(activity.isBusy)
        #expect(en { backfill(snapshot(), [transfer()]) }.text == "Uploading IMG_1234.MOV to Google Drive (ten@example.com) · 1.0 / 2.0 GB (50%)")
    }

    @Test func theBackfillCardFollowsTheJobOriginNotTheSource() {
        let imported = transfer(source: .folder(), backfill: true)
        if case .transfer = vi({ backfill(snapshot(), [imported]) }) {} else { Issue.record("an imported file uploading as backfill belongs on the card") }
        // A backfill file wins over another file that moves at the same time, even a longer-running one.
        let incremental = transfer(.copy, to: "NAS", account: nil, ago: 60, backfill: false)
        let mine = transfer(ago: 5, backfill: true)
        #expect(vi { backfill(snapshot(), [incremental, mine]) }.text.hasPrefix("Đang upload IMG_1234.MOV lên Google Drive"))
    }

    @Test func theBackfillCardNeverSaysPreparingWhileAnyFileMoves() {
        let incremental = transfer(backfill: false)
        #expect(vi { backfill(snapshot(), [incremental]) }.text == "Đang upload IMG_1234.MOV lên Google Drive (ten@example.com) · 1,0 / 2,0 GB (50%)")
        let other = transfer(source: .folder(), backfill: false)
        if case .transfer = vi({ backfill(snapshot(nextRetryAt: t0.addingTimeInterval(60)), [other]) }) {} else { Issue.record("a moving file beats a wait") }
        // Only when nothing moves at all does the card explain a wait.
        #expect(vi { backfill(snapshot(), [transfer(ago: 0.2, backfill: false)]) } == .preparing("Đang chuẩn bị file tiếp theo…"))
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
        #expect(vi { backfill(away) } == .waiting("NAS chưa kết nối"))
        #expect(en { backfill(away) } == .waiting("NAS is not connected"))
        // One destination that is away is no reason to wait while another can still make progress.
        let working = snapshot(destinations: [destination("NAS", .unavailable(.offline)), destination("Drive", .active)])
        #expect(vi { backfill(working) } == .preparing("Đang chuẩn bị file tiếp theo…"))
        let retry = snapshot(nextRetryAt: t0.addingTimeInterval(125))
        #expect(vi { backfill(retry) } == .waiting("Chờ thử lại sau 2:05"))
        #expect(en { backfill(retry) } == .waiting("Retrying in 2:05"))
        // The countdown ran out and the next snapshot has not arrived yet.
        let due = snapshot(nextRetryAt: t0.addingTimeInterval(-5))
        #expect(vi { backfill(due) } == .preparing("Đang thử lại…"))
        #expect(en { backfill(due) } == .preparing("Retrying…"))
    }

    @Test func aRunningTransferWinsOverAnyWaitingReason() {
        let retry = snapshot(nextRetryAt: t0.addingTimeInterval(125))
        if case .transfer = vi({ backfill(retry, [transfer()]) }) {} else { Issue.record("a moving file is not waiting") }
    }

    // MARK: Import card

    @Test func theImportCardShowsOnlyItsOwnTransfers() {
        let mine = SourceID.folder(), other = SourceID.folder()
        let download = transfer(.download(.dropbox), source: mine, to: nil, account: "ten@example.com")
        #expect(vi { CardActivityText.importJob(mine, transfers: [transfer(source: other), download], now: t0) }?.text
            == "Đang tải IMG_1234.MOV từ Dropbox (ten@example.com) · 1,0 / 2,0 GB (50%)")
        #expect(CardActivityText.importJob(mine, transfers: [transfer(source: other)], now: t0) == nil)
        #expect(CardActivityText.importJob(mine, transfers: [], now: t0) == nil)
    }

    // MARK: Header

    @Test func theHeaderStaysFullWhenNoCardShowsTheSameFile() {
        // No backfill is unfinished: the Backfill card is gone, so the header keeps the full line.
        let incremental = transfer(backfill: false)
        let none = vi { OverallStatusText.make(snapshot: snapshot(done: 0, total: 0), disk: .ok, settings: GlobalSettings(), now: t0, transfers: [incremental]) }
        #expect(none.subtitle == "Đang upload IMG_1234.MOV lên Google Drive (ten@example.com) · 1,0 / 2,0 GB (50%)")
        // An unfinished backfill: its card shows the moving file, so the header is short.
        let backfilling = vi { OverallStatusText.make(snapshot: snapshot(done: 10, total: 100), disk: .ok, settings: GlobalSettings(), now: t0, transfers: [incremental]) }
        #expect(backfilling.subtitle == "Đang upload IMG_1234.MOV · 50%")
        #expect(backfilling.subtitleLine == FittedLine(prefix: "Đang upload ", lead: "IMG_1234.MOV", detail: " · 50%"), "only the file name is cut in the middle")
        // A finished import has no card.
        var finished = snapshot(done: 0, total: 0)
        let id = SourceID.folder()
        finished.imports = [ImportSnapshot(id: id, displayName: "Trip", status: .completed, createdAt: t0, finishedAt: t0)]
        let plain = vi { OverallStatusText.make(snapshot: finished, disk: .ok, settings: GlobalSettings(), now: t0, transfers: [transfer(source: id, backfill: false)]) }
        #expect(plain.subtitle.contains("lên Google Drive"))
        // Only the newest running import has a card.
        let older = SourceID.folder(), newest = SourceID.folder()
        var two = snapshot(done: 0, total: 0)
        two.imports = [
            ImportSnapshot(id: newest, displayName: "New", status: .importing, createdAt: t0),
            ImportSnapshot(id: older, displayName: "Old", status: .importing, createdAt: t0.addingTimeInterval(-60)),
        ]
        let hidden = vi { OverallStatusText.make(snapshot: two, disk: .ok, settings: GlobalSettings(), now: t0, transfers: [transfer(source: older, backfill: false)]) }
        #expect(hidden.subtitle.contains("lên Google Drive"), "the older import has no card: \(hidden.subtitle)")
        let shown = vi { OverallStatusText.make(snapshot: two, disk: .ok, settings: GlobalSettings(), now: t0, transfers: [transfer(source: newest, backfill: false)]) }
        #expect(shown.subtitle == "Đang upload IMG_1234.MOV · 50%")
    }

    @Test func theHeaderAndTheCardPickTheSameImportWhenOthersWait() {
        let older = SourceID.folder(), newest = SourceID.folder()
        var two = snapshot(done: 0, total: 0)
        two.imports = [
            ImportSnapshot(id: newest, displayName: "New", status: .importing, createdAt: t0),
            ImportSnapshot(id: older, displayName: "Old", status: .importing, createdAt: t0.addingTimeInterval(-60)),
        ]
        let waiting = ImportQueue.snapshot(id: .folder(), kind: .localFolder, account: nil, displayName: "Waiting", now: t0)
        // The card heads with the first recorded import even though an entry waits (and the app lists waiting ones after it).
        let cardHead = ImportQueueLayout.queueRows(ImportQueue.merged(queued: [waiting], running: two.imports)).first?.item.id
        #expect(cardHead == newest)
        let onNewest = vi { OverallStatusText.make(snapshot: two, disk: .ok, settings: GlobalSettings(), now: t0, transfers: [transfer(source: newest, backfill: false)]) }
        #expect(onNewest.subtitle == "Đang upload IMG_1234.MOV · 50%", "its full line is on the card, so the header is short")
        let onOlder = vi { OverallStatusText.make(snapshot: two, disk: .ok, settings: GlobalSettings(), now: t0, transfers: [transfer(source: older, backfill: false)]) }
        #expect(onOlder.subtitle.contains("lên Google Drive"))
        // Only a waiting entry: no transfer belongs to it, and the header keeps the full line.
        let none = snapshot(done: 0, total: 0)
        let plain = vi { OverallStatusText.make(snapshot: none, disk: .ok, settings: GlobalSettings(), now: t0, transfers: [transfer(backfill: false)]) }
        #expect(plain.subtitle.contains("lên Google Drive"))
    }

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
        let importId = SourceID.folder()
        importing.imports = [ImportSnapshot(id: importId, displayName: "Trip", status: .importing, createdAt: t0)]
        let mine = transfer(source: importId, backfill: false)
        let shortToo = vi { OverallStatusText.make(snapshot: importing, disk: .ok, settings: GlobalSettings(), now: t0, transfers: [mine]) }
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
