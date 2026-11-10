import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultAppSupport
@testable import PhotoVaultEngine

struct TransferLineTextTests {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private let gib: Int64 = 1 << 30

    private func vi<T>(_ body: () -> T) -> T { L10n.$override.withValue(.vi, operation: body) }
    private func en<T>(_ body: () -> T) -> T { L10n.$override.withValue(.en, operation: body) }

    private func item(
        _ kind: TransferKind, _ name: String = "IMG_1234.MOV", to destination: String? = nil, done: Int64 = 0, total: Int64? = nil,
        startedAgo: TimeInterval = 5
    ) -> TransferProgress {
        TransferProgress(kind: kind, fileName: name, destinationName: destination, bytesDone: done, bytesTotal: total,
                         startedAt: t0.addingTimeInterval(-startedAgo))
    }

    private func line(_ items: [TransferProgress]) -> String? { TransferLineText.make(items, now: t0) }

    @Test func uploadLineNamesTheFileDestinationAndProgress() {
        let upload = item(.upload, to: "Google Drive", done: Int64(1.2 * Double(gib)), total: Int64(2.6 * Double(gib)))
        #expect(vi { line([upload]) } == "Đang upload IMG_1234.MOV lên Google Drive · 1,2 / 2,6 GB (46%)")
        #expect(en { line([upload]) } == "Uploading IMG_1234.MOV to Google Drive · 1.2 / 2.6 GB (46%)")
    }

    @Test func eachKindHasItsOwnVerb() {
        let big = 5 * gib
        #expect(vi { line([item(.exportFromPhotos, done: gib, total: big)]) } == "Đang xuất IMG_1234.MOV từ Photos · 1,0 / 5,0 GB (20%)")
        #expect(vi { line([item(.download(.dropbox), done: gib, total: big)]) } == "Đang tải IMG_1234.MOV từ Dropbox · 1,0 / 5,0 GB (20%)")
        #expect(vi { line([item(.download(.googleDrive), done: gib, total: big)]) }?.hasPrefix("Đang tải IMG_1234.MOV từ Google Drive") == true)
        #expect(vi { line([item(.download(.localFolder), done: gib, total: big)]) }?.hasPrefix("Đang đọc IMG_1234.MOV từ thư mục Mac") == true)
        #expect(vi { line([item(.copy, to: "NAS Nhà", done: gib, total: big)]) } == "Đang chép IMG_1234.MOV vào NAS Nhà · 1,0 / 5,0 GB (20%)")
        #expect(en { line([item(.exportFromPhotos, done: gib, total: big)]) } == "Exporting IMG_1234.MOV from Photos · 1.0 / 5.0 GB (20%)")
        #expect(en { line([item(.download(.dropbox), done: gib, total: big)]) } == "Downloading IMG_1234.MOV from Dropbox · 1.0 / 5.0 GB (20%)")
        #expect(en { line([item(.copy, to: "Home NAS", done: gib, total: big)]) } == "Copying IMG_1234.MOV to Home NAS · 1.0 / 5.0 GB (20%)")
    }

    @Test func differentUnitsKeepBothAndAnUnknownTotalShowsOnlyBytesDone() {
        let small = item(.upload, to: "Drive", done: 300 << 20, total: 2 * gib)
        #expect(vi { line([small]) } == "Đang upload IMG_1234.MOV lên Drive · 300 MB / 2,0 GB (14%)")
        let unknown = item(.download(.dropbox), done: 1_500 << 20, total: nil)
        #expect(vi { line([unknown]) } == "Đang tải IMG_1234.MOV từ Dropbox · 1,5 GB")
        let notStarted = item(.exportFromPhotos, done: 0, total: nil)
        #expect(vi { line([notStarted]) } == "Đang xuất IMG_1234.MOV từ Photos")
    }

    @Test func bytesPastTheTotalAreClampedAfterARetry() {
        let retried = item(.download(.dropbox), done: 3 * gib, total: 2 * gib)
        #expect(vi { line([retried]) } == "Đang tải IMG_1234.MOV từ Dropbox · 2,0 / 2,0 GB (100%)")
    }

    @Test func aTransferShowsOnlyAfterItHasRunForASecond() {
        let fresh = item(.upload, to: "Drive", done: 5, total: 10, startedAgo: 0.4)
        #expect(line([fresh]) == nil)
        #expect(TransferLineText.make([fresh], now: t0.addingTimeInterval(0.7)) != nil)
        #expect(line([]) == nil)
    }

    @Test func theLongestRunningTransferIsShownAndTheRestAreCounted() {
        let old = item(.upload, "old.MOV", to: "Drive", done: 1, total: 2, startedAgo: 60)
        let mid = item(.copy, "mid.MOV", to: "NAS", done: 1, total: 2, startedAgo: 30)
        let fresh = item(.exportFromPhotos, "fresh.MOV", done: 1, total: 2, startedAgo: 0.2)
        let vietnamese = vi { line([mid, fresh, old]) }
        #expect(vietnamese?.contains("old.MOV") == true)
        // The fresh one is not visible yet, so only one other file is counted.
        #expect(vietnamese?.hasSuffix(" · +1 file khác") == true, "\(vietnamese ?? "")")
        let third = item(.download(.dropbox), "third.MOV", done: 1, total: 2, startedAgo: 10)
        #expect(vi { line([old, mid, third]) }?.hasSuffix(" · +2 file khác") == true)
        #expect(en { line([old, mid, third]) }?.hasSuffix(" · +2 more files") == true)
        #expect(en { line([old, mid]) }?.hasSuffix(" · +1 more file") == true)
    }

    @Test func longNamesAreTruncatedInTheMiddleKeepingTheExtension() {
        let name = "Kỳ nghỉ Đà Lạt 2026 - bản dựng cuối cùng (final v3).MOV"
        let shown = TransferLineText.middleTruncated(name, limit: 24)
        #expect(shown.count == 24 && shown.contains("…") && shown.hasSuffix(".MOV") && shown.hasPrefix("Kỳ nghỉ"))
        #expect(TransferLineText.middleTruncated("IMG_1.MOV", limit: 24) == "IMG_1.MOV")
        #expect(TransferLineText.middleTruncated("abcdef", limit: 1) == "…")
        let upload = item(.upload, name, to: "Google Drive", done: 1, total: 2)
        #expect(vi { line([upload]) }?.contains(name) == false)
    }

    @Test func theHeaderSubtitleShowsTheTransferWhileSyncing() {
        var snapshot = EngineSnapshot(
            overall: .syncing, scanState: .complete, destinations: [], backfillDoneAssets: 0, backfillTotalAssets: 0,
            bytesUploaded: 0, etaSeconds: nil, pending: 0, deferred: 0, skipped: 0, missingRemote: 0, updatedAt: t0)
        let upload = item(.upload, to: "Google Drive", done: gib, total: 2 * gib)
        let with = vi { OverallStatusText.make(snapshot: snapshot, disk: .ok, settings: GlobalSettings(), now: t0, transfers: [upload]) }
        #expect(with.title == "Đang đồng bộ" && with.isWorking)
        #expect(with.subtitle == "Đang upload IMG_1234.MOV lên Google Drive · 1,0 / 2,0 GB (50%)")
        let without = vi { OverallStatusText.make(snapshot: snapshot, disk: .ok, settings: GlobalSettings(), now: t0, transfers: []) }
        #expect(without.subtitle.contains("sync lần cuối"))
        // Problems keep their own subtitle.
        snapshot.overall = .paused
        let paused = vi { OverallStatusText.make(snapshot: snapshot, disk: .ok, settings: GlobalSettings(), now: t0, transfers: [upload]) }
        #expect(paused.subtitle == "Bấm Tiếp tục tất cả để chạy lại")
    }
}
