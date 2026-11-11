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

    @Test func cloudTransfersNameTheAccount() {
        func account(_ kind: TransferKind, to destination: String? = nil, email: String = "ten@example.com") -> TransferProgress {
            var transfer = item(kind, to: destination, done: gib, total: 2 * gib)
            transfer.accountEmail = email
            return transfer
        }
        #expect(vi { line([account(.download(.dropbox))]) } == "Đang tải IMG_1234.MOV từ Dropbox (ten@example.com) · 1,0 / 2,0 GB (50%)")
        #expect(en { line([account(.download(.googleDrive))]) } == "Downloading IMG_1234.MOV from Google Drive (ten@example.com) · 1.0 / 2.0 GB (50%)")
        #expect(vi { line([account(.upload, to: "Google Drive")]) } == "Đang upload IMG_1234.MOV lên Google Drive (ten@example.com) · 1,0 / 2,0 GB (50%)")
        #expect(vi { line([account(.copy, to: "NAS")]) } == "Đang chép IMG_1234.MOV vào NAS · 1,0 / 2,0 GB (50%)")
        #expect(vi { line([account(.exportFromPhotos)]) } == "Đang xuất IMG_1234.MOV từ Photos · 1,0 / 2,0 GB (50%)")
        let long = vi { line([account(.download(.dropbox), email: "a.very.long.mailbox.name.here@subdomain.example.com")]) } ?? ""
        #expect(!long.contains("a.very.long.mailbox.name.here@subdomain.example.com") && long.contains("…") && long.contains(".com)"))
        let missing = item(.download(.dropbox), done: gib, total: 2 * gib)
        #expect(vi { line([missing]) }?.contains("(") == true)
        #expect(vi { line([missing]) }?.contains("@") == false)
    }

    @Test func aLongTransferShowsElapsedTimeSoItVisiblyMovesBetweenChunks() {
        func upload(_ seconds: TimeInterval) -> TransferProgress {
            item(.upload, to: "Drive", done: 262_144, total: 2 * gib, startedAgo: seconds)
        }
        #expect(vi { line([upload(9)]) }?.hasSuffix("(0%)") == true)
        #expect(vi { line([upload(10)]) } == "Đang upload IMG_1234.MOV lên Drive · 256 KB / 2,0 GB (0%) · 0:10")
        #expect(vi { line([upload(125)]) }?.hasSuffix(" · 2:05") == true)
        #expect(en { line([upload(3725)]) }?.hasSuffix(" · 1:02:05") == true)
        let two = vi { line([upload(125), item(.copy, "b", to: "NAS", done: 1, total: 2, startedAgo: 5)]) }
        #expect(two?.hasSuffix(" · 2:05 · +1 file khác") == true, "\(two ?? "")")
    }

    @Test func anExportThatHasReceivedNoBytesIsAnICloudDownload() {
        let waiting = item(.exportFromPhotos, done: 0, total: 3 * gib, startedAgo: 2)
        #expect(vi { line([waiting]) } == "Đang tải IMG_1234.MOV từ iCloud")
        #expect(en { line([waiting]) } == "Downloading IMG_1234.MOV from iCloud")
        let long = item(.exportFromPhotos, done: 0, total: nil, startedAgo: 95)
        #expect(vi { line([long]) } == "Đang tải IMG_1234.MOV từ iCloud · 1:35")
        // Once bytes arrive it is an export again.
        let moving = item(.exportFromPhotos, done: gib, total: 3 * gib, startedAgo: 95)
        #expect(vi { line([moving]) } == "Đang xuất IMG_1234.MOV từ Photos · 1,0 / 3,0 GB (33%) · 1:35")
    }

    @Test func differentUnitsKeepBothAndAnUnknownTotalShowsOnlyBytesDone() {
        let small = item(.upload, to: "Drive", done: 300 << 20, total: 2 * gib)
        #expect(vi { line([small]) } == "Đang upload IMG_1234.MOV lên Drive · 300 MB / 2,0 GB (14%)")
        let unknown = item(.download(.dropbox), done: 1_500 << 20, total: nil)
        #expect(vi { line([unknown]) } == "Đang tải IMG_1234.MOV từ Dropbox · 1,5 GB")
        let notStarted = item(.exportFromPhotos, done: 0, total: nil)
        #expect(vi { line([notStarted]) } == "Đang tải IMG_1234.MOV từ iCloud")
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

    @Test func theFittedLineHoldsTheFileNameApartSoACutKeepsTheExtension() {
        let name = "Kỳ nghỉ Đà Lạt 2026 - bản dựng cuối cùng (final v3).MOV"
        let shortened = TransferLineText.middleTruncated(name, limit: TransferLineText.nameLimit)
        var cloud = item(.download(.googleDrive), name, done: gib, total: 2 * gib, startedAgo: 75)
        cloud.accountEmail = "ten@example.com"
        let kinds: [TransferProgress] = [
            item(.upload, name, to: "Google Drive", done: gib, total: 2 * gib), item(.upload, name, done: gib, total: 2 * gib),
            item(.copy, name, to: "NAS", done: gib, total: 2 * gib), item(.exportFromPhotos, name, done: 0, total: nil),
            item(.exportFromPhotos, name, done: gib, total: 2 * gib), item(.download(.dropbox), name, done: gib, total: nil),
            item(.download(.localFolder), name, done: gib, total: 2 * gib), cloud,
        ]
        for transfer in kinds {
            for language in AppLanguage.allCases {
                for style in [TransferLineText.Style.full, .short] {
                    let fitted = L10n.$override.withValue(language) { TransferLineText.fitted([transfer], now: t0, style: style) }
                    let joined = L10n.$override.withValue(language) { TransferLineText.make([transfer], now: t0, style: style) }
                    #expect(fitted?.lead == name, "the view cuts the name to its width")
                    #expect(fitted.map { !$0.prefix.isEmpty && !$0.prefix.contains(".MOV") && !$0.place.contains(".MOV") } == true)
                    #expect(fitted.map { $0.prefix + shortened + $0.place + $0.detail + $0.others } == joined)
                    #expect(fitted?.help.contains(name) == true, "the tooltip names the file in full")
                    #expect(fitted.map { !$0.text.contains("\u{E000}") && !$0.help.contains("\u{E000}") } == true)
                }
            }
        }
    }

    @Test func theFittedLineKeepsThePlaceTheNumbersAndTheOthersApart() {
        var upload = item(.upload, to: "Google Drive", done: gib, total: 2 * gib, startedAgo: 75)
        upload.accountEmail = "a.very.long.mailbox.name.here@subdomain.example.com"
        let other = item(.copy, "b.MOV", to: "NAS", done: 1, total: 2, startedAgo: 5)
        let fitted = en { TransferLineText.fitted([upload, other], now: t0) }
        #expect(fitted?.prefix == "Uploading ")
        #expect(fitted?.lead == "IMG_1234.MOV")
        #expect(fitted?.place.hasPrefix(" to Google Drive (") == true && fitted?.place.contains("…") == true)
        #expect(fitted?.detail == " · 1.0 / 2.0 GB (50%) · 1:15")
        #expect(fitted?.others == " · +1 more file")
        #expect(fitted?.help == "Uploading IMG_1234.MOV to Google Drive (a.very.long.mailbox.name.here@subdomain.example.com) · 1.0 / 2.0 GB (50%) · 1:15 · +1 more file")
        #expect(vi { TransferLineText.fitted([upload], now: t0, style: .short) } == FittedLine(prefix: "Đang upload ", lead: "IMG_1234.MOV", detail: " · 50%"))
        let iCloud = item(.exportFromPhotos, done: 0, total: nil)
        #expect(en { TransferLineText.fitted([iCloud], now: t0) } == FittedLine(prefix: "Downloading ", lead: "IMG_1234.MOV", place: " from iCloud"))
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
