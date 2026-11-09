import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultAppSupport

struct ActivityPresenterTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return calendar
    }

    private let now = Date(timeIntervalSince1970: 1_794_200_000) // 2026-11-09 ~11:33 local
    private let drive = DestinationID.googleDrive
    private let nas = DestinationID.local()

    private func events() -> [ActivityEvent] {
        [
            ActivityEvent(id: 5, at: now.addingTimeInterval(-600), kind: .statusChanged, destinationId: drive, message: "status paused(rootTrashed)"),
            ActivityEvent(id: 4, at: now.addingTimeInterval(-3600), kind: .renamed, destinationId: nas, message: "folder renamed to Đà Lạt"),
            ActivityEvent(id: 3, at: now.addingTimeInterval(-86400), kind: .moved, destinationId: drive, message: "14 files moved"),
            ActivityEvent(id: 2, at: now.addingTimeInterval(-2 * 86400), kind: .missingFile, destinationId: nas, message: "27 files missing"),
            ActivityEvent(id: 1, at: now.addingTimeInterval(-2 * 86400 - 60), kind: .recovered, destinationId: nil, message: "restored 18402 files"),
        ]
    }

    private var names: [DestinationID: String] { [drive: "Google Drive", nas: "Synology NAS"] }

    private func groups(_ filter: ActivityFilter = .all, _ query: String = "") -> [ActivityDayGroup] {
        ActivityPresenter.groups(events(), filter: filter, query: query, destinationNames: names, now: now, calendar: calendar)
    }

    @Test func groupsByDayKeepingOrder() {
        let result = groups()
        #expect(result.map(\.heading) == ["Hôm nay", "Hôm qua", "Thứ 7, 07/11/2026"])
        #expect(result.map { $0.rows.count } == [2, 1, 2])
        #expect(result[0].rows[0].id == 5)
        #expect(result[0].rows[0].destinationName == "Google Drive")
        #expect(result[2].rows[1].destinationName == nil)
    }

    @Test func filtersByKind() {
        for filter in ActivityFilter.allCases where filter != .all {
            let rows = groups(filter).flatMap(\.rows)
            #expect(rows.count == 1)
            #expect(filter.matches(rows[0].kind))
        }
        #expect(ActivityFilter.all.matches(.notice))
        #expect(groups(.status).first?.rows.first?.message == "status paused(rootTrashed)")
    }

    @Test func searchIgnoresCaseAndDiacritics() {
        #expect(groups(.all, "da lat").flatMap(\.rows).map(\.id) == [4])
        #expect(groups(.all, "SYNOLOGY").flatMap(\.rows).map(\.id) == [4, 2])
        #expect(groups(.all, "khôi phục").flatMap(\.rows).map(\.id) == [1])
        #expect(groups(.all, "zzz").isEmpty)
        #expect(groups(.all, "   ").flatMap(\.rows).count == 5)
    }

    @Test func combinesFilterAndSearch() {
        #expect(groups(.move, "Synology").isEmpty)
        #expect(groups(.move, "drive").flatMap(\.rows).map(\.id) == [3])
    }

    @Test func everyKindHasALabel() {
        #expect(ActivityKind.allCases.allSatisfy { !ActivityPresenter.kindLabel($0).isEmpty })
    }
}
