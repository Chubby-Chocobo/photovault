import Foundation
import PhotoVaultCore
import PhotoVaultEngine
import Testing
@testable import PhotoVaultAppSupport

@Suite struct ImportQueueLayoutTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func queued(_ name: String) -> ImportSnapshot {
        ImportQueue.snapshot(id: .folder(), kind: .localFolder, account: nil, displayName: name, now: t0)
    }

    private func running(_ name: String, status: SourceStatus = .scanning) -> ImportSnapshot {
        ImportSnapshot(id: .folder(), displayName: name, status: status, createdAt: t0)
    }

    private func finished(_ name: String, status: SourceStatus = .completed, at seconds: TimeInterval, created: TimeInterval = 0) -> ImportSnapshot {
        ImportSnapshot(id: .folder(), displayName: name, status: status, createdAt: t0.addingTimeInterval(created), finishedAt: t0.addingTimeInterval(seconds))
    }

    @Test func theRunningImportComesFirstThenTheQueueInOrder() {
        let q1 = queued("Q1"), q2 = queued("Q2")
        let run = running("Run")
        let done = finished("Done", at: 10)
        let rows = ImportQueueLayout.queueRows(ImportQueue.merged(queued: [q1, q2], running: [run, done]))
        #expect(rows.map(\.item.displayName) == ["Run", "Q1", "Q2"])
        #expect(rows.map(\.number) == [1, 2, 3])
        #expect(rows.map(\.isQueued) == [false, true, true])
    }

    @Test func badgesNameRunningAndPlaceInLine() {
        let rows = ImportQueueLayout.queueRows(ImportQueue.merged(queued: [queued("A"), queued("B")], running: [running("R")]))
        L10n.$override.withValue(.vi) { #expect(rows.map(\.badge) == ["Đang chạy", "Chờ · thứ 1", "Chờ · thứ 2"]) }
        L10n.$override.withValue(.en) { #expect(rows.map(\.badge) == ["Running", "Waiting · 1st", "Waiting · 2nd"]) }
    }

    @Test func aQueueOfOnlyWaitingImportsStartsAtOne() {
        let rows = ImportQueueLayout.queueRows([queued("A")])
        #expect(rows.map(\.number) == [1] && rows[0].isQueued)
    }

    @Test func finishedImportsAreNewestFirstAndKeepCancelled() {
        let old = finished("Old", at: 10), new = finished("New", at: 90), cancelled = finished("Cancelled", status: .cancelled, at: 50)
        let open = running("Open")
        #expect(ImportQueueLayout.finishedRows([old, open, new, cancelled]).map(\.displayName) == ["New", "Cancelled", "Old"])
    }

    @Test func titlesAndEmptyStateAreBilingual() {
        L10n.$override.withValue(.vi) {
            #expect(ImportQueueLayout.queueTitle == "Hàng đợi nhập")
            #expect(ImportQueueLayout.finishedTitle == "Đã nhập xong")
            #expect(ImportQueueLayout.emptyText == "Không có lần nhập nào đang chạy hoặc chờ")
        }
        L10n.$override.withValue(.en) {
            #expect(ImportQueueLayout.queueTitle == "Import queue")
            #expect(ImportQueueLayout.finishedTitle == "Finished imports")
            #expect(ImportQueueLayout.emptyText == "No imports are running or waiting")
        }
    }

    @Test func eachProviderHasItsOwnIcon() {
        let names = [
            ImportProviderSymbol.name(kind: .localFolder, synced: nil),
            ImportProviderSymbol.name(kind: .localFolder, synced: .googleDrive),
            ImportProviderSymbol.name(kind: .localFolder, synced: .dropbox),
            ImportProviderSymbol.name(kind: .googleDrive, synced: nil),
            ImportProviderSymbol.name(kind: .dropbox, synced: nil),
        ]
        #expect(Set(names).count == names.count)
        #expect(names[0] == "folder")
    }

    @Test func thePopoverShowsTheHeadAndUpToTwoWaitingNames() {
        let rows = ImportQueueLayout.queueRows(ImportQueue.merged(queued: [queued("A"), queued("B"), queued("C")], running: [running("R")]))
        let summary = try! #require(ImportQueueLayout.popoverSummary(rows))
        #expect(summary.head.item.displayName == "R")
        #expect(summary.waitingCount == 3 && summary.waitingNames == ["A", "B"])
        L10n.$override.withValue(.vi) { #expect(summary.waitingLine == "+3 đang chờ: A, B…") }
        L10n.$override.withValue(.en) { #expect(summary.waitingLine == "+3 waiting: A, B…") }
    }

    @Test func thePopoverListsAllWaitingNamesWhenTheyFit() {
        let rows = ImportQueueLayout.queueRows(ImportQueue.merged(queued: [queued("A"), queued("B")], running: [running("R")]))
        let summary = try! #require(ImportQueueLayout.popoverSummary(rows))
        L10n.$override.withValue(.en) { #expect(summary.waitingLine == "+2 waiting: A, B") }
        #expect(ImportQueueLayout.popoverSummary(ImportQueueLayout.queueRows([running("R")]))?.waitingLine == nil)
        #expect(ImportQueueLayout.popoverSummary([]) == nil)
    }

    @Test func aLoneQueuedImportHeadsThePopoverCard() {
        let summary = try! #require(ImportQueueLayout.popoverSummary(ImportQueueLayout.queueRows([queued("A")])))
        #expect(summary.head.isQueued && summary.waitingLine == nil)
    }
}
