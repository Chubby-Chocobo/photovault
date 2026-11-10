import Foundation
import PhotoVaultCore
@testable import PhotoVaultEngine
import Testing
@testable import PhotoVaultAppSupport

@Suite struct PopoverJobVisibilityTests {
    private func importJob(_ status: SourceStatus, found: Int = 10, processed: Int = 10, uploaded: Int = 4, total: Int = 10) -> ImportSnapshot {
        ImportSnapshot(
            id: .folder(), displayName: "Trip", status: status, createdAt: Date(timeIntervalSince1970: 1_800_000_000), found: found,
            processed: processed, imported: processed, filesUploaded: uploaded, filesTotal: total)
    }

    private func backfill(done: Int, total: Int) -> EngineSnapshot {
        EngineSnapshot(
            overall: .idle, scanState: .complete, destinations: [], backfillDoneAssets: done, backfillTotalAssets: total,
            bytesUploaded: 0, etaSeconds: nil, pending: 0, deferred: 0, skipped: 0, missingRemote: 0,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func anImportStaysWhileItReadsOrOnlyUploads() {
        #expect(PopoverJobVisibility.shows(importJob: importJob(.scanning, processed: 3, uploaded: 0)))
        // Every file is read; uploads still run. The job stays open (importing) until they end.
        let uploading = importJob(.importing, found: 10, processed: 10, uploaded: 4, total: 10)
        #expect(uploading.processed == uploading.found)
        #expect(PopoverJobVisibility.shows(importJob: uploading))
        #expect(PopoverJobVisibility.shows(importJob: importJob(.offline)))
        #expect(ImportProgressText.running([uploading]).count == 1)
    }

    @Test func aFinishedImportIsHidden() {
        #expect(!PopoverJobVisibility.shows(importJob: importJob(.completed, uploaded: 10)))
        #expect(!PopoverJobVisibility.shows(importJob: importJob(.cancelled)))
        #expect(ImportProgressText.running([importJob(.completed), importJob(.cancelled)]).isEmpty)
        #expect(ImportProgressText.finished([importJob(.completed), importJob(.cancelled)]).count == 2)
    }

    @Test func backfillFollowsTheSameRule() {
        #expect(PopoverJobVisibility.shows(backfill: backfill(done: 3, total: 10)))
        #expect(!PopoverJobVisibility.shows(backfill: backfill(done: 10, total: 10)))
        #expect(!PopoverJobVisibility.shows(backfill: backfill(done: 0, total: 0)))
        #expect(BackfillText.isRunning(backfill(done: 3, total: 10)))
    }

    @Test func theRuleIsOneFunction() {
        #expect(PopoverJobVisibility.shows(finished: false))
        #expect(!PopoverJobVisibility.shows(finished: true))
    }
}
