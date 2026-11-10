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
    }
}
