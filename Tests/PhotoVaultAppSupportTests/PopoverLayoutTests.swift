import Testing
@testable import PhotoVaultAppSupport

struct PopoverLayoutTests {
    @Test func theLimitLeavesRoomForTheActionRowsAsMeasured() {
        #expect(PopoverLayout.contentLimit(visibleScreenHeight: 900, actionsHeight: 220) == 900 - 220 - PopoverLayout.chromeAllowance)
        // An open NAS folder list makes the action rows taller, so the content may be less tall.
        #expect(PopoverLayout.contentLimit(visibleScreenHeight: 900, actionsHeight: 400) == 900 - 400 - PopoverLayout.chromeAllowance)
    }

    @Test func aVerySmallScreenStillGetsTheMinimumContentArea() {
        #expect(PopoverLayout.contentLimit(visibleScreenHeight: 300, actionsHeight: 220) == PopoverLayout.minimumContentLimit)
    }

    @Test func nothingIsSetBeforeTheFirstMeasurement() {
        #expect(PopoverContentHeight().height(limit: 600) == nil)
    }

    @Test func theContentAreaFitsWhatItShows() {
        var height = PopoverContentHeight()
        height.opened()
        height.measured(310)
        #expect(height.height(limit: 600) == 310)
    }

    @Test func whileOpenTheAreaGrowsButNeverShrinks() {
        var height = PopoverContentHeight()
        height.measured(310)
        height.opened()
        height.measured(420) // a card appears
        #expect(height.height(limit: 600) == 420)
        height.measured(310) // and goes away: the action rows stay where they are
        #expect(height.height(limit: 600) == 420)
    }

    @Test func reopeningFitsTheContentAgain() {
        var height = PopoverContentHeight()
        height.opened()
        height.measured(420)
        height.measured(310)
        height.closed()
        #expect(height.height(limit: 600) == 310)
        height.opened()
        #expect(height.height(limit: 600) == 310)
    }

    @Test func whileClosedTheAreaFollowsTheContent() {
        var height = PopoverContentHeight()
        height.closed()
        height.measured(420)
        height.measured(310)
        #expect(height.height(limit: 600) == 310)
        #expect(!height.isOpen)
    }

    @Test func theScreenLimitWinsAndTallContentScrolls() {
        var height = PopoverContentHeight()
        height.opened()
        height.measured(900)
        #expect(height.height(limit: 600) == 600)
        // A smaller limit (the NAS list opened, or another screen) applies at once, even while open.
        #expect(height.height(limit: 500) == 500)
        height.measured(300)
        #expect(height.height(limit: 800) == 800)
    }
}
