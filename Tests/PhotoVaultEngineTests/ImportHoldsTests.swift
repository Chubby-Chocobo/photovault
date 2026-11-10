import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultEngine

@Suite struct ImportHoldsTests {
    private let id = SourceID.folder()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theWaitDoublesFromThirtySecondsUpToAnHour() {
        let holds = ImportHolds()
        var waits: [TimeInterval] = []
        var now = start
        for _ in 0..<10 {
            _ = holds.noteFailure(id, group: "g", now: now)
            let retry = holds.failingGroups(id, now: now.addingTimeInterval(3601)).due
            #expect(retry == ["g"])
            // The first moment the group is due again is its retry time.
            var low = 0.0, high = 3601.0
            while high - low > 0.5 {
                let mid = (low + high) / 2
                if holds.failingGroups(id, now: now.addingTimeInterval(mid)).due.isEmpty { low = mid } else { high = mid }
            }
            waits.append(high.rounded())
            now = now.addingTimeInterval(high)
        }
        #expect(waits == [30, 60, 120, 240, 480, 960, 1920, 3600, 3600, 3600])
    }

    @Test func aGroupIsGivenUpAfterTenFailuresSpanningADay() {
        let holds = ImportHolds()
        let results = (0..<26).map { holds.noteFailure(id, group: "g", now: start.addingTimeInterval(Double($0) * 3600)) }
        #expect(results.firstIndex { $0.giveUp } == 24, "the failure a day after the first")
        #expect(results.first?.isFresh == true && results.dropFirst().allSatisfy { !$0.isFresh })
    }

    @Test func tenQuickFailuresAreNotEnoughAndNeitherAreFewSlowOnes() {
        let quick = ImportHolds()
        #expect(!(0..<40).map { quick.noteFailure(id, group: "g", now: start.addingTimeInterval(Double($0))) }.contains { $0.giveUp })
        let slow = ImportHolds()
        #expect(!slow.noteFailure(id, group: "g", now: start).giveUp)
        #expect(!slow.noteFailure(id, group: "g", now: start.addingTimeInterval(90 * 3600)).giveUp, "two failures are not ten")
    }

    @Test func aLongSleepDoesNotRestartTheCount() {
        let holds = ImportHolds()
        for index in 0..<9 { _ = holds.noteFailure(id, group: "g", now: start.addingTimeInterval(Double(index) * 3600)) }
        #expect(holds.noteFailure(id, group: "g", now: start.addingTimeInterval(30 * 3600)).giveUp)
    }

    @Test func aDecidedGroupStartsFromScratch() {
        let holds = ImportHolds()
        for index in 0..<23 { _ = holds.noteFailure(id, group: "g", now: start.addingTimeInterval(Double(index) * 3600)) }
        holds.settled(id, group: "g")
        let failure = holds.noteFailure(id, group: "g", now: start.addingTimeInterval(25 * 3600))
        #expect(!failure.giveUp && failure.isFresh)
    }

    @Test func groupsAreCountedApartAndOrderedBySoonestRetry() {
        let holds = ImportHolds()
        _ = holds.noteFailure(id, group: "b", now: start)
        _ = holds.noteFailure(id, group: "a", now: start.addingTimeInterval(10))
        _ = holds.noteFailure(id, group: "a", now: start.addingTimeInterval(20))
        #expect(holds.failingGroups(id, now: start).all == ["b", "a"])
        #expect(holds.failingGroups(id, now: start.addingTimeInterval(31)).due == ["b"])
    }
}
