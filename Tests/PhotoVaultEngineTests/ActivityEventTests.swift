import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// What the engine writes to "Hoạt động gần đây" while things work (FR-63).
@Suite struct ActivityEventTests {
    private func harness() async throws -> Harness {
        let h = try await Harness.organized()
        try await h.update {
            $0.viewByDeviceEnabled = false
            $0.viewByPlaceEnabled = false
            $0.viewFavoritesEnabled = false
            $0.sidecarJsonEnabled = false
            $0.sidecarXmpEnabled = false
        }
        try h.addDrive(scope: .full)
        return h
    }

    private func events(_ h: Harness, _ kind: ActivityKind) throws -> [ActivityEvent] {
        try h.read { db in try ActivityRepository.recent(db) }.filter { $0.kind == kind }
    }

    @Test func renamingAVisibleDayFolderIsRecordedWithBothNames() async throws {
        let h = try await harness()
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        await h.geocoder.seed(hanoi, en: hanoiEnglish, local: hanoiVietnamese)
        for index in 0..<3 { await h.add(h.snapshot("p\(index)", daysAgo: 3, location: daLat), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.settle()
        await h.add(h.snapshot("far", daysAgo: 3, location: hanoi))
        await h.settle()
        let renames = try events(h, .renamed)
        #expect(renames.map(\.message).contains("“\(organizationDay) Đà Lạt” → “\(organizationDay)”"))
        #expect(renames.allSatisfy { $0.destinationId == .googleDrive })
    }

    @Test func statusChangesAreRecordedOnceWithTheOldAndNewStatus() async throws {
        let h = try await harness()
        let now = Date()
        try L10n.$override.withValue(.vi) {
            try h.write { db in
                try DestinationRepository.setStatus(db, id: .googleDrive, status: .unavailable(.offline), now: now)
                try DestinationRepository.setStatus(db, id: .googleDrive, status: .unavailable(.offline), now: now)
                try DestinationRepository.setStatus(db, id: .googleDrive, status: .active, now: now)
            }
        }
        let rows = try events(h, .statusChanged)
        #expect(rows.map(\.message) == [
            "Không khả dụng · mất kết nối → Đang hoạt động",
            "Đang hoạt động → Không khả dụng · mất kết nối",
        ], "newest first; the unchanged status wrote nothing")
        #expect(rows.allSatisfy { $0.destinationId == .googleDrive })
    }

    @Test func aSyncThatUploadsRecordsTheCountAndTheEndOfTheBackfillOnce() async throws {
        let h = try await harness()
        for index in 0..<3 { await h.add(h.snapshot("old\(index)", daysAgo: 5), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.settle()
        let first = try events(h, .milestone)
        #expect(first.contains { $0.message.contains("3") && $0.destinationId == .googleDrive })
        #expect(first.filter { $0.message == SyncMilestones.backfillText(done: 3, deferred: 0) }.count == 1)

        await h.add(h.snapshot("new", daysAgo: 0))
        await h.settle()
        let second = try events(h, .milestone)
        #expect(second.filter { $0.message == SyncMilestones.backfillText(done: 3, deferred: 0) }.count == 1, "announced once")
        #expect(second.contains { $0.message == SyncMilestones.uploadedText(1) })
    }

    @Test func aBackfillIsNotAnnouncedWhileItsJobsWait() async throws {
        let h = try await harness()
        await h.add(h.snapshot("old", daysAgo: 5), recordChange: false)
        try await h.baseline(.googleDrive)
        try h.write { db in try SyncMilestones.noteBackfill(db, id: .googleDrive, drained: true, now: Date()) }
        #expect(try events(h, .milestone).isEmpty)
    }
}

@Suite struct MovePassActivityTests {
    @Test func fewChangesGetOneRowEach() {
        var pass = MovePassActivity()
        pass.renamed(from: "2026-04-26", to: "2026-04-26 Hà Nội")
        pass.moved(into: "2026-04-27")
        pass.moved(into: "2026-04-27")
        let rows = L10n.$override.withValue(.vi) { pass.events() }
        #expect(rows.map(\.kind) == [.renamed, .moved])
        #expect(rows[0].message == "“2026-04-26” → “2026-04-26 Hà Nội”")
        #expect(rows[1].message == "Đã chuyển 2 file vào “2026-04-27”")
    }

    @Test func manyChangesCollapseIntoOneSummaryEach() {
        var pass = MovePassActivity()
        for day in 1...40 { pass.renamed(from: "2026-04-\(day)", to: "2026-04-\(day) Hà Nội") }
        for day in 1...12 { pass.moved(into: "2026-05-\(day)") }
        let rows = L10n.$override.withValue(.en) { pass.events() }
        #expect(rows.count == 2)
        #expect(rows[0].message == "Renamed 40 folders, for example “2026-04-1” → “2026-04-1 Hà Nội”")
        #expect(rows[1].message == "Moved 12 files into 12 other folders")
    }

    @Test func nothingChangedWritesNothing() {
        #expect(MovePassActivity().events().isEmpty)
    }
}
