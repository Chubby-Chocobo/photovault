import Foundation
import PhotoVaultCore
@testable import PhotoVaultEngine
import Testing
@testable import PhotoVaultAppSupport

@Suite struct ImportProgressTextTests {
    func item(
        _ status: SourceStatus, found: Int = 0, processed: Int = 0, imported: Int = 0, duplicates: Int = 0,
        unsupported: Int = 0, failed: Int = 0, uploaded: Int = 0, total: Int = 0, name: String = "Trip"
    ) -> ImportSnapshot {
        ImportSnapshot(
            id: .folder(), displayName: name, status: status, createdAt: Date(timeIntervalSince1970: 1_800_000_000), found: found,
            processed: processed, imported: imported, duplicates: duplicates, unsupported: unsupported, failed: failed,
            filesUploaded: uploaded, filesTotal: total)
    }

    func vi<T>(_ body: () -> T) -> T { L10n.$override.withValue(.vi, operation: body) }
    func en<T>(_ body: () -> T) -> T { L10n.$override.withValue(.en, operation: body) }

    @Test func statusLabels() {
        vi {
            #expect(ImportProgressText.statusLabel(.scanning) == "Đang đọc thư mục…")
            #expect(ImportProgressText.statusLabel(.importing) == "Đang upload…")
            #expect(ImportProgressText.statusLabel(.completed) == "Hoàn tất")
            #expect(ImportProgressText.statusLabel(.cancelled) == "Đã huỷ")
            #expect(ImportProgressText.statusLabel(.offline).hasPrefix("Thư mục không truy cập được"))
        }
        en {
            #expect(ImportProgressText.statusLabel(.scanning) == "Reading folder…")
            #expect(ImportProgressText.statusLabel(.importing) == "Uploading…")
            #expect(ImportProgressText.statusLabel(.completed) == "Done")
            #expect(ImportProgressText.statusLabel(.cancelled) == "Cancelled")
        }
    }

    @Test func progressLineShowsBothStagesAndDuplicates() {
        let running = item(.importing, found: 3500, processed: 1240, duplicates: 120, uploaded: 800, total: 1100)
        vi { #expect(ImportProgressText.progressLine(running) == "Đọc 1.240/3.500 · Upload 800/1.100 · 120 đã có") }
        en { #expect(ImportProgressText.progressLine(running) == "Read 1,240/3,500 · Upload 800/1,100 · 120 already backed up") }
        let early = item(.scanning, found: 10, processed: 4)
        vi { #expect(ImportProgressText.progressLine(early) == "Đọc 4/10") }
        let listing = item(.scanning)
        vi { #expect(ImportProgressText.progressLine(listing) == "") }
    }

    @Test func oneBarFillsReadFirstHalfAndUploadSecondHalf() {
        #expect(ImportProgressText.fraction(item(.scanning)) == 0)
        #expect(ImportProgressText.fraction(item(.scanning, found: 100, processed: 50)) == 0.25)
        #expect(ImportProgressText.fraction(item(.scanning, found: 100, processed: 100, uploaded: 0, total: 100)) == 0.5)
        #expect(ImportProgressText.fraction(item(.importing, found: 100, processed: 100, uploaded: 50, total: 100)) == 0.75)
        #expect(ImportProgressText.fraction(item(.importing, found: 100, processed: 100)) == 1, "nothing to upload")
        #expect(ImportProgressText.fraction(item(.completed, found: 5, processed: 5)) == 1)
    }

    @Test func summaryOfAFinishedJob() {
        let done = item(.completed, found: 20, processed: 20, imported: 12, duplicates: 5, unsupported: 2, failed: 1)
        vi { #expect(ImportProgressText.summaryLine(done) == "12 mới · 5 đã có · 2 bỏ qua · 1 lỗi") }
        en { #expect(ImportProgressText.summaryLine(done) == "12 new · 5 already backed up · 2 skipped · 1 failed") }
    }

    @Test func menuBarCardTexts() {
        vi {
            #expect(ImportProgressText.menuTitle(folderName: "Trip") == "Nhập từ “Trip”")
            #expect(ImportProgressText.moreImports(0) == nil)
            #expect(ImportProgressText.moreImports(2) == "+ 2 lần nhập khác")
        }
        en {
            #expect(ImportProgressText.menuTitle(folderName: "Trip") == "Importing from “Trip”")
            #expect(ImportProgressText.moreImports(1) == "+ 1 more import")
            #expect(ImportProgressText.moreImports(3) == "+ 3 more imports")
        }
    }

    @Test func runningAndFinishedAreSeparated() {
        let a = item(.scanning), b = item(.completed), c = item(.offline), d = item(.cancelled)
        #expect(ImportProgressText.running([a, b, c, d]).count == 2)
        #expect(ImportProgressText.finished([a, b, c, d]).count == 2)
    }

    @Test func notificationNamesTheFolderAndCountsOnly() {
        vi {
            let text = ImportNotificationText.make(folderName: "Trip", imported: 1240, known: 30)
            #expect(text.body == "Đã nhập xong “Trip”: 1.240 ảnh mới, 30 đã có")
            #expect(!text.title.isEmpty)
        }
        en {
            let text = ImportNotificationText.make(folderName: "Trip", imported: 1, known: 0)
            #expect(text.body == "Finished importing “Trip”: 1 new photo, 0 already backed up")
        }
    }

    @Test func theOverallHeaderSaysImportingWhenAnImportIsTheOnlyWork() {
        var snapshot = EngineSnapshot(
            overall: .syncing, scanState: .complete, destinations: [], backfillDoneAssets: 0, backfillTotalAssets: 0,
            bytesUploaded: 0, etaSeconds: nil, pending: 0, deferred: 0, skipped: 0, missingRemote: 0, updatedAt: Date())
        snapshot.imports = [item(.scanning, found: 10, processed: 2)]
        let presentation = vi { OverallStatusText.make(snapshot: snapshot, disk: .ok, settings: GlobalSettings(), now: Date()) }
        #expect(presentation.title == "Đang nhập ảnh" && presentation.isWorking)
        en { #expect(OverallStatusText.make(snapshot: snapshot, disk: .ok, settings: GlobalSettings(), now: Date()).title == "Importing photos") }
        snapshot.backfillTotalAssets = 10
        #expect(vi { OverallStatusText.make(snapshot: snapshot, disk: .ok, settings: GlobalSettings(), now: Date()).title } == "Đang backfill")
        snapshot.backfillTotalAssets = 0
        snapshot.imports = [item(.completed)]
        snapshot.overall = .idle
        #expect(vi { OverallStatusText.make(snapshot: snapshot, disk: .ok, settings: GlobalSettings(), now: Date()).title } == "Đã đồng bộ")
    }

    @Test func waitingForPhotosAccessIsSaidInsteadOfReadingTheFolder() {
        let reading = item(.scanning)
        vi {
            #expect(ImportProgressText.waitingForPhotos(reading, photosAllowsReading: false)?.hasPrefix("Đang chờ quyền truy cập Photos") == true)
            #expect(ImportProgressText.waitingForPhotos(reading, photosAllowsReading: true) == nil)
            #expect(ImportProgressText.waitingForPhotos(item(.completed), photosAllowsReading: false) == nil)
            #expect(ImportProgressText.waitingForPhotos(item(.offline), photosAllowsReading: false) == nil)
        }
        en { #expect(ImportProgressText.waitingForPhotos(item(.importing), photosAllowsReading: false)?.hasPrefix("Waiting for Photos access") == true) }
    }

    @Test func moreImportsGroupsThousands() {
        vi { #expect(ImportProgressText.moreImports(1_200) == "+ 1.200 lần nhập khác") }
        en {
            #expect(ImportProgressText.moreImports(1_200) == "+ 1,200 more imports")
            #expect(ImportProgressText.moreImports(1) == "+ 1 more import")
        }
        #expect(ImportProgressText.moreImports(0) == nil)
    }

    @Test func onlyAnImportThatWasOpenAndIsNowCompletedIsNewlyCompleted() {
        let running = item(.importing, name: "A")
        let done = item(.completed, name: "A")
        let other = item(.completed, name: "B")
        let before: [SourceID: SourceStatus] = [running.id: .importing, other.id: .completed]
        let finished = ImportProgressText.newlyCompleted(before: before, imports: [done.with(id: running.id), other])
        #expect(finished.map(\.displayName) == ["A"], "an import already finished at the last snapshot is not announced again")
        #expect(ImportProgressText.newlyCompleted(before: [running.id: .completed], imports: [done.with(id: running.id)]).isEmpty)
        #expect(ImportProgressText.newlyCompleted(before: [:], imports: [done]).isEmpty, "unknown at the last snapshot: only remembered")
    }
}

private extension ImportSnapshot {
    func with(id: SourceID) -> ImportSnapshot {
        var copy = self
        copy.id = id
        return copy
    }
}
