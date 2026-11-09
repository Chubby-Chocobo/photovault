import Foundation
import Testing
@testable import PhotoVaultAppSupport

struct ProgressWatchdogTests {
    private func stalled(_ dog: inout ProgressWatchdog<Int>, _ value: Int, now: Date) -> Bool { dog.isStalled(value, now: now) }

    @Test func stallsOnlyAfterTheLimitWithoutChange() {
        let start = Date(timeIntervalSince1970: 1_000)
        var dog = ProgressWatchdog<Int>(limit: 600, now: start)
        #expect(!stalled(&dog, 1, now: start))
        #expect(!stalled(&dog, 1, now: start.addingTimeInterval(599)))
        #expect(stalled(&dog, 1, now: start.addingTimeInterval(600)))
    }

    @Test func anyChangeResetsTheClock() {
        let start = Date(timeIntervalSince1970: 1_000)
        var dog = ProgressWatchdog<Int>(limit: 600, now: start)
        #expect(!stalled(&dog, 1, now: start))
        #expect(!stalled(&dog, 2, now: start.addingTimeInterval(500)))
        #expect(!stalled(&dog, 2, now: start.addingTimeInterval(1_000)))
        #expect(stalled(&dog, 2, now: start.addingTimeInterval(1_100)))
    }
}
