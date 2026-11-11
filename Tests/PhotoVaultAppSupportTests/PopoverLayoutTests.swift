import Testing
@testable import PhotoVaultAppSupport

struct PopoverLayoutTests {
    @Test func theRunningContentIsOneHeightWhateverItHolds() {
        // A laptop screen and a large display give the same fixed height.
        #expect(PopoverLayout.runningContentHeight(visibleScreenHeight: 900) == 520)
        #expect(PopoverLayout.runningContentHeight(visibleScreenHeight: 1_400) == 520)
    }

    @Test func aSmallScreenKeepsRoomForTheActionRows() {
        #expect(PopoverLayout.runningContentHeight(visibleScreenHeight: 700) == 700 - PopoverLayout.actionsAllowance)
        #expect(PopoverLayout.runningContentHeight(visibleScreenHeight: 300) == PopoverLayout.minimumContentHeight)
    }
}
