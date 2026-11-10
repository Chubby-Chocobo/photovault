import PhotoVaultCore
import Testing
@testable import PhotoVaultAppSupport

@Suite struct CloudFlowStageTests {
    @Test func aFlowWalksFromBrowserToReadStepToStarting() {
        var flow = CloudFlowTracker()
        #expect(flow.stage == .idle)
        let id = flow.begin()
        #expect(flow.stage == .browser)
        flow.reachReadStep(id)
        #expect(flow.stage == .readStep)
        flow.startingImport(id)
        #expect(flow.stage == .starting)
        flow.end(id)
        #expect(flow.stage == .idle)
    }

    @Test func aLateReadStepNeverReopensTheBrowserState() {
        var flow = CloudFlowTracker()
        let id = flow.begin()
        flow.startingImport(id)
        flow.reachReadStep(id)
        #expect(flow.stage == .starting)
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
        flow.startingImport(old)
        flow.end(old)
        #expect(flow.stage == .browser)
        flow.end(new)
        #expect(flow.stage == .idle)
    }

    @Test func textsNameTheStage() {
        L10n.$override.withValue(.en) {
            #expect(CloudFlowStage.browser.text == "Waiting for sign-in in the browser…")
            #expect(CloudFlowStage.readStep.text.hasPrefix("Step 2 of 2"))
            #expect(CloudFlowStage.starting.text.hasPrefix("Access granted. Waiting for the current sync"))
        }
        L10n.$override.withValue(.vi) {
            #expect(CloudFlowStage.starting.text.hasPrefix("Đã cho phép. Đang chờ việc đồng bộ hiện tại"))
        }
    }
}
