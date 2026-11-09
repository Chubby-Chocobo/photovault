import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultEngine

@Suite struct ImportHoldsTests {
    private let id = SourceID.folder()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func tries(_ holds: ImportHolds, every interval: TimeInterval, from first: Date, count: Int) -> [Bool] {
        (0..<count).map { holds.noteFailure(id, group: "g", now: first.addingTimeInterval(Double($0) * interval)) }
    }

    @Test func aGroupIsGivenUpOnlyAfterADayAndTenTries() {
        let holds = ImportHolds()
        let results = tries(holds, every: 3600, from: start, count: 26)
        #expect(results.firstIndex(of: true) == 24, "the try a day after the first")
        #expect(!tries(ImportHolds(), every: 60, from: start, count: 9).contains(true))
    }

    @Test func aFailureLongAfterTheLastOneStartsTheCountAgain() {
        let holds = ImportHolds()
        #expect(!holds.noteFailure(id, group: "g", now: start))
        #expect(!holds.noteFailure(id, group: "g", now: start.addingTimeInterval(30 * 3600)))
        let later = start.addingTimeInterval(30 * 3600)
        let results = tries(holds, every: 3600, from: later.addingTimeInterval(3600), count: 23)
        #expect(!results.contains(true), "a day has not passed since the restart")
    }

    @Test func aDecidedGroupStartsFromScratch() {
        let holds = ImportHolds()
        _ = tries(holds, every: 3600, from: start, count: 23)
        holds.settled(id, group: "g")
        #expect(!holds.noteFailure(id, group: "g", now: start.addingTimeInterval(25 * 3600)))
    }

    @Test func groupsAreCountedApart() {
        let holds = ImportHolds()
        _ = tries(holds, every: 3600, from: start, count: 24)
        #expect(!holds.noteFailure(id, group: "other", now: start.addingTimeInterval(24 * 3600)))
    }
}
