import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultAppSupport

@Suite struct HistoryTextAndCSVTests {
    private let vietnam: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return calendar
    }()
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)  // 2026-10-26 07:33:20 UTC

    // MARK: Status and reasons

    @Test func aDestinationStatusSaysWhereTheFileIsWhyAndWhenItWasChecked() {
        let done = FileDestinationStatus(destinationId: .googleDrive, resType: .photo, state: .done, checkedAt: t0, checkResult: .hashVerified)
        let failed = FileDestinationStatus(destinationId: .googleDrive, resType: .photo, state: .deferred, reason: .uploadFailures, detail: "noSpace")
        L10n.$override.withValue(.vi) {
            #expect(HistoryText.status(done, calendar: vietnam) == "Đã lên · kiểm tra 26/10/2026 14:33: nguyên vẹn (đã so checksum)")
            #expect(HistoryText.status(failed, calendar: vietnam)
                == "Lỗi, sẽ thử lại · Upload lỗi nhiều lần liền, sẽ tự thử lại sau 24 giờ: Đích đã hết dung lượng.")
        }
        L10n.$override.withValue(.en) {
            #expect(HistoryText.status(done, calendar: vietnam) == "Backed up · checked 26 Oct 2026 14:33: intact (checksum verified)")
        }
    }

    @Test func reasonsAreReadableAndUnknownDetailsStayOut() {
        L10n.$override.withValue(.en) {
            #expect(HistoryReasonText.upload(reason: .foreignFile, detail: "foreignFile")
                == "The destination already holds a file of that name that PhotoVault did not write")
            #expect(HistoryReasonText.upload(reason: .permanentError, detail: "itemRejected(/Users/someone/x.jpg)")
                == "The destination does not accept this file: The destination rejected this file")
            #expect(HistoryReasonText.upload(reason: .uploadFailures, detail: "server(503)")?.hasSuffix("The destination server returned an error. Try again later.") == true)
            #expect(HistoryReasonText.upload(reason: nil, detail: "something new") == nil)
            #expect(HistoryReasonText.upload(reason: nil, detail: nil) == nil)
            #expect(HistoryReasonText.importItem(state: .failed, reason: "read") == "The file could not be read")
            #expect(HistoryReasonText.importItem(state: .unsupported, reason: "companion") == "A companion file, not a photo or video")
            #expect(HistoryReasonText.importItem(state: .imported, reason: nil) == nil)
        }
        for reason in JobStateReason.allCases {
            L10n.$override.withValue(.vi) { #expect(!HistoryReasonText.text(reason).isEmpty) }
        }
    }

    @Test func aDuplicateNamesTheBackedUpFile() {
        L10n.$override.withValue(.vi) {
            #expect(HistoryReasonText.duplicate(of: "IMG_0042.HEIC", capturedAt: t0, calendar: vietnam)
                == "Trùng với IMG_0042.HEIC (chụp 26/10/2026 14:33) đã backup")
        }
        L10n.$override.withValue(.en) {
            #expect(HistoryReasonText.duplicate(of: nil, capturedAt: nil) == "Same as a file, already backed up")
        }
    }

    @Test func aRemovedDestinationAndApproximateTimesAreMarked() {
        L10n.$override.withValue(.en) {
            #expect(HistoryText.destination(.googleDrive, names: [:]) == "Removed destination")
            #expect(HistoryText.time(t0, approximate: true, calendar: vietnam) == "≈ 26 Oct 2026 14:33")
        }
    }

    // MARK: Run summaries

    @Test func aRunSummaryHasItsPeriodDurationAndTotals() {
        let run = BackfillRunRow(
            id: 1, trigger: .destinationAdded, destinationId: .googleDrive, startedAt: t0, finishedAt: t0.addingTimeInterval(9 * 3600 + 30 * 60),
            approximate: false, totals: [.uploaded: OutcomeTotal(files: 1_200, bytes: 3 << 30), .failed: OutcomeTotal(files: 3, bytes: 12 << 20)])
        L10n.$override.withValue(.vi) {
            #expect(HistoryRunText.title(run, destinationNames: [.googleDrive: "Google Drive"]) == "Thêm đích · Google Drive")
            #expect(HistoryRunText.period(start: run.startedAt, end: run.finishedAt, calendar: vietnam)
                == "26/10/2026 14:33 → 27/10/2026 00:03 · 9 giờ 30 phút")
            #expect(HistoryRunText.totals(run.totals) == "Đã lên 1.200 file (3,0 GB) · Lỗi 3 file (12 MB)")
            #expect(HistoryRunText.period(start: t0, end: nil, calendar: vietnam).hasSuffix("→ đang chạy"))
            #expect(HistoryRunText.totals([:]) == "Chưa có file nào xong")
        }
        L10n.$override.withValue(.en) {
            #expect(HistoryRunText.duration(45) == "45 seconds")
            #expect(HistoryRunText.duration(3600) == "1 hour")
            #expect(HistoryRunText.duration(2 * 86_400 + 4 * 3600 + 59) == "2 days 4 hours")
            #expect(HistoryRunText.importTotals([.imported: OutcomeTotal(files: 1, bytes: 1 << 20), .duplicate: OutcomeTotal(files: 2, bytes: 0)])
                == "Imported 1 file (1 MB) · Already backed up 2 files (0 B)")
        }
    }

    // MARK: CSV

    @Test func csvFieldsAreQuotedOnlyWhenNeeded() {
        #expect(HistoryCSV.field("IMG_0001.HEIC") == "IMG_0001.HEIC")
        #expect(HistoryCSV.field("Biển, Nha Trang.jpg") == "\"Biển, Nha Trang.jpg\"")
        #expect(HistoryCSV.field("say \"hi\".jpg") == "\"say \"\"hi\"\".jpg\"")
        #expect(HistoryCSV.field("two\nlines.jpg") == "\"two\nlines.jpg\"")
        #expect(HistoryCSV.field("crlf\r\nname.jpg") == "\"crlf\r\nname.jpg\"")
        #expect(HistoryCSV.field("Ảnh đẹp 🌅.HEIC") == "Ảnh đẹp 🌅.HEIC")
        #expect(HistoryCSV.line(["a", "b,c"]) == "a,\"b,c\"\r\n")
    }

    @Test func csvFieldsThatLookLikeFormulasAreDefused() {
        #expect(HistoryCSV.field("=HYPERLINK(\"x\")") == "\"'=HYPERLINK(\"\"x\"\")\"")
        #expect(HistoryCSV.field("+1.jpg") == "'+1.jpg")
        #expect(HistoryCSV.field("-edit.jpg") == "'-edit.jpg")
        #expect(HistoryCSV.field("@home.jpg") == "'@home.jpg")
        #expect(HistoryCSV.field("a=b.jpg") == "a=b.jpg")
    }

    @Test func anEventLineHasEveryColumnInOrder() {
        let row = TransferEventRow(
            id: 1, at: t0, approximate: true, jobId: 1, destinationId: .googleDrive, assetKey: .local("a"), resType: .photo,
            sourceId: .photos, origin: .backfill, runId: 1, outcome: .failed, bytes: 2_048, reason: .tooLargeForRule, detail: nil,
            fileName: "Đà Lạt, sáng.HEIC", mediaType: .image, isRaw: false, capturedAt: t0, deletedFromLibraryAt: nil)
        let zone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        L10n.$override.withValue(.en) {
            #expect(HistoryCSV.eventHeader == "Time,Approximate,File,Destination,Result,Cause,Size (bytes),Taken,Reason\r\n")
            #expect(HistoryCSV.eventLine(row, destinationNames: [.googleDrive: "Drive"], timeZone: zone)
                == "2026-10-26T14:33:20+07:00,≈,\"Đà Lạt, sáng.HEIC\",Drive,Failed,Backfill,2048,2026-10-26T14:33:20+07:00,The file is larger than the limit set for this destination\r\n")
        }
        let item = ImportItemRow(relativePath: "trip/a,b.jpg", state: .duplicate, reason: nil, sizeBytes: 5, assetKey: nil, duplicateOfName: "IMG_1.HEIC")
        L10n.$override.withValue(.en) {
            #expect(HistoryCSV.importLine(item) == "\"trip/a,b.jpg\",Already backed up,5,,IMG_1.HEIC\r\n")
        }
        #expect(HistoryCSV.byteOrderMark.utf8.elementsEqual([0xEF, 0xBB, 0xBF]))
    }

    // MARK: Links

    @Test func driveLinksAndFinderPathsRefuseAnythingOdd() {
        #expect(HistoryLinks.driveFile(remoteId: "1AbC-_9")?.absoluteString == "https://drive.google.com/file/d/1AbC-_9/view")
        #expect(HistoryLinks.driveFile(remoteId: "../x") == nil)
        #expect(HistoryLinks.driveFile(remoteId: "") == nil)
        let root = URL(fileURLWithPath: "/Volumes/Backup/PhotoVault")
        #expect(HistoryLinks.localFile(root: root, relativePath: "Camera Uploads/2026-11-10/IMG 1.HEIC")?.path
            == "/Volumes/Backup/PhotoVault/Camera Uploads/2026-11-10/IMG 1.HEIC")
        for bad in ["../etc/passwd", "a/../../b", "/etc/passwd", "a//b", "./a", ""] {
            #expect(HistoryLinks.localFile(root: root, relativePath: bad) == nil, "\(bad)")
        }
    }
}
