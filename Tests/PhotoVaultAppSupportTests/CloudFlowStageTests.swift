import Foundation
import PhotoVaultCore
import PhotoVaultEngine
import Testing
@testable import PhotoVaultAppSupport

@Suite struct CloudFlowStageTests {
    @Test func aFlowWalksFromBrowserToReadStepAndEnds() {
        var flow = CloudFlowTracker()
        #expect(flow.stage == .idle)
        let id = flow.begin()
        #expect(flow.stage == .browser)
        flow.reachReadStep(id)
        #expect(flow.stage == .readStep)
        flow.end(id)
        #expect(flow.stage == .idle)
    }

    @Test func aLateReadStepNeverReopensAnEndedFlow() {
        var flow = CloudFlowTracker()
        let id = flow.begin()
        flow.end(id)
        flow.reachReadStep(id)
        #expect(flow.stage == .idle)
    }

    @Test func aLateNoticeFromAnEarlierFlowIsIgnored() {
        var flow = CloudFlowTracker()
        let old = flow.begin()
        flow.end(old)
        let new = flow.begin()
        flow.reachReadStep(old)
        flow.end(old)
        #expect(flow.stage == .browser)
        flow.end(new)
        #expect(flow.stage == .idle)
    }

    @Test func textsNameTheStage() {
        L10n.$override.withValue(.en) {
            #expect(CloudFlowStage.browser.text == "Waiting for sign-in in the browser…")
            #expect(CloudFlowStage.readStep.text.hasPrefix("Step 2 of 2"))
        }
    }
}

@Suite struct QueuedImportTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func queued(_ name: String = "Trip", kind: SourceKind = .googleDrive) -> ImportSnapshot {
        ImportQueue.snapshot(id: .folder(), kind: kind, account: "me@example.com", displayName: name, now: now)
    }

    private func running(id: SourceID) -> ImportSnapshot {
        ImportSnapshot(id: id, kind: .googleDrive, account: "me@example.com", displayName: "Trip", status: .scanning, createdAt: now, found: 3)
    }

    @Test func aQueuedImportIsRunningVisibleAndNamed() {
        let item = queued()
        #expect(ImportQueue.isQueued(item))
        #expect(PopoverJobVisibility.shows(importJob: item))
        #expect(ImportProgressText.running([item]).count == 1 && ImportProgressText.finished([item]).isEmpty)
        #expect(item.displayName == "Trip" && item.account == "me@example.com" && item.kind == .googleDrive)
        #expect(CloudImportText.providerLabel(kind: item.kind, account: item.account) == "Google Drive · me@example.com")
        #expect(ImportProgressText.progressLine(item).isEmpty)
        #expect(!CloudImportText.needsSignIn(item))
    }

    @Test func theStatusSaysItWaitsForItsTurn() {
        let item = queued()
        L10n.$override.withValue(.vi) { #expect(ImportProgressText.statusLabel(item) == "Chờ đến lượt") }
        L10n.$override.withValue(.en) { #expect(ImportProgressText.statusLabel(item) == "Waiting for its turn") }
    }

    @Test func aRealImportIsNotQueued() {
        #expect(!ImportQueue.isQueued(running(id: .folder())))
        var offline = running(id: .folder())
        offline.statusReason = "diskFull"
        #expect(!ImportQueue.isQueued(offline))
    }

    @Test func queuedImportsComeFirstInTheOrderTheyWereAdded() {
        let a = queued("A"), b = queued("B")
        let real = running(id: .folder())
        #expect(ImportQueue.merged(queued: [a, b], running: [real]).map(\.id) == [a.id, b.id, real.id])
    }

    @Test func theRealImportReplacesItsQueuedEntryInPlace() {
        let a = queued("A"), b = queued("B")
        let realA = running(id: a.id)
        let other = running(id: .folder())
        let merged = ImportQueue.merged(queued: [a, b], running: [realA, other])
        #expect(merged.map(\.id) == [b.id, realA.id, other.id])
        #expect(!merged.contains { ImportQueue.isQueued($0) && $0.id == a.id })
    }

    @Test func aGrantWithNoImportIsAnOrphan() {
        let kept = SourceID.folder(), lost = SourceID.folder()
        let stored = [CloudTokenAccount.importGrant(kept), CloudTokenAccount.importGrant(lost), CloudTokenAccount.dropbox, "google-refresh-token"]
        #expect(CloudImportKeychain.orphanGrants(stored: stored, knownImports: [kept]) == [CloudTokenAccount.importGrant(lost)])
        #expect(CloudImportKeychain.orphanGrants(stored: stored, knownImports: [kept, lost]).isEmpty)
        // The Dropbox account's token and its e-mail are not import grants.
        #expect(CloudImportKeychain.orphanGrants(stored: [CloudTokenAccount.dropbox, CloudTokenAccount.dropboxEmail], knownImports: []).isEmpty)
    }
}

@Suite struct QueuedFolderImportTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aSyncedFolderPickIsQueuedWithItsProviderLabelAndPath() {
        let config = SourceConfig(account: "me@example.com", locationPaths: ["Google Drive/Trips"], syncedProvider: .googleDrive)
        let item = ImportQueue.snapshot(
            id: .folder(), kind: .localFolder, account: config.account, syncedProvider: config.syncedCloudProvider, displayName: "Trips", now: now,
            location: ImportLocation.make(kind: .localFolder, config: config))
        #expect(ImportQueue.isQueued(item) && PopoverJobVisibility.shows(importJob: item))
        L10n.$override.withValue(.vi) {
            #expect(CloudImportText.providerLabel(kind: item.kind, account: item.account, syncedProvider: item.syncedProvider) == "Google Drive (trên máy này) · me@example.com")
            #expect(ImportProgressText.statusLabel(item) == "Chờ đến lượt")
        }
        #expect(item.location?.paths == ["Google Drive/Trips"] && item.displayName == "Trips")
    }

    @Test func aMacFolderPickIsQueuedAsAFolderOnThisMac() {
        let config = SourceConfig(locationPaths: ["~/Pictures/Trip"])
        let item = ImportQueue.snapshot(
            id: .folder(), kind: .localFolder, account: nil, displayName: "Trip", now: now,
            location: ImportLocation.make(kind: .localFolder, config: config))
        L10n.$override.withValue(.vi) {
            #expect(CloudImportText.providerLabel(kind: item.kind, account: item.account, syncedProvider: item.syncedProvider) == "Thư mục trên Mac")
        }
        #expect(item.location?.paths == ["~/Pictures/Trip"] && item.syncedProvider == nil)
    }

    @Test func theRealFolderImportReplacesItsQueuedEntry() {
        let queued = ImportQueue.snapshot(id: .folder(), kind: .localFolder, account: nil, displayName: "Trip", now: now)
        let real = ImportSnapshot(id: queued.id, displayName: "Trip", status: .scanning, createdAt: now)
        #expect(ImportQueue.merged(queued: [queued], running: [real]) == [real])
    }
}

@Suite struct QueueWaitTextTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func queued() -> ImportSnapshot {
        ImportQueue.snapshot(id: .folder(), kind: .localFolder, account: nil, displayName: "X", now: now)
    }

    @Test func positionCountsOnlyQueuedEntriesInOrder() {
        let a = queued(), b = queued(), c = queued()
        let real = ImportSnapshot(id: .folder(), displayName: "R", status: .scanning, createdAt: now)
        #expect(ImportQueue.position(of: b.id, queued: [a, b, c]) == ImportQueue.Position(index: 2, total: 3))
        #expect(ImportQueue.position(of: real.id, queued: [a, b, c]) == nil)
    }

    @Test func aLoneEntryHasNoOrdinal() {
        L10n.$override.withValue(.vi) {
            #expect(ImportQueue.waitTitle(ImportQueue.Position(index: 1, total: 1)) == "Chờ đến lượt")
            #expect(ImportQueue.waitTitle(ImportQueue.Position(index: 2, total: 3)) == "Chờ đến lượt · thứ 2")
        }
        L10n.$override.withValue(.en) {
            #expect(ImportQueue.waitTitle(ImportQueue.Position(index: 1, total: 1)) == "Waiting for its turn")
            #expect(ImportQueue.waitTitle(ImportQueue.Position(index: 1, total: 2)) == "Waiting for its turn · 1st in line")
            #expect(ImportQueue.waitTitle(ImportQueue.Position(index: 2, total: 4)) == "Waiting for its turn · 2nd in line")
            #expect(ImportQueue.waitTitle(ImportQueue.Position(index: 3, total: 4)) == "Waiting for its turn · 3rd in line")
            #expect(ImportQueue.waitTitle(ImportQueue.Position(index: 4, total: 4)) == "Waiting for its turn · 4th in line")
            #expect(ImportQueue.waitTitle(ImportQueue.Position(index: 11, total: 12)) == "Waiting for its turn · 11th in line")
            #expect(ImportQueue.waitTitle(ImportQueue.Position(index: 22, total: 22)) == "Waiting for its turn · 22nd in line")
        }
    }

    @Test func theReasonNamesWhatTheEngineIsDoing() {
        L10n.$override.withValue(.vi) {
            #expect(ImportQueue.waitReason(uploading: true) == "đang chờ app upload xong file đang chạy")
            #expect(ImportQueue.waitReason(uploading: false) == "đang chờ lượt đồng bộ hiện tại")
        }
        L10n.$override.withValue(.en) {
            #expect(ImportQueue.waitReason(uploading: true) == "waiting for the upload in progress to finish")
            #expect(ImportQueue.waitReason(uploading: false) == "waiting for the current sync turn")
        }
    }

    @Test func aCancelThatWaitsIsSaid() {
        L10n.$override.withValue(.en) { #expect(ImportQueue.cancellingText == "Cancelling · waiting for its turn") }
        L10n.$override.withValue(.vi) { #expect(ImportQueue.cancellingText == "Đang huỷ · chờ đến lượt") }
    }
}
