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
        for index in 0..<3 {
            var moved = try #require(try await h.fakePhotos.assets(localIds: ["p\(index)"]).first)
            moved.location = hanoi
            await h.fakePhotos.update(moved)
        }
        await h.settle()
        let renames = try events(h, .renamed)
        #expect(renames.contains { $0.message.contains("“\(organizationDay) Đà Lạt” → “\(organizationDay) Hà Nội”") })
        #expect(renames.allSatisfy { $0.destinationId == .googleDrive })
    }

    @Test func statusChangesAreRecordedOnceWithTheOldAndNewStatus() async throws {
        let h = try await harness()
        let now = Date()
        try L10n.$override.withValue(.vi) {
            try h.write { db in
                try DestinationRepository.setStatus(db, id: .googleDrive, status: .unavailable(.offline), now: now)
                try DestinationRepository.setStatus(db, id: .googleDrive, status: .unavailable(.offline), now: now)
                try DestinationRepository.setStatus(db, id: .googleDrive, status: .active, now: now.addingTimeInterval(3 * 3600))
            }
        }
        let rows = try events(h, .statusChanged)
        #expect(rows.map(\.message) == [
            "Không khả dụng · mất kết nối → Đang hoạt động",
            "Đang hoạt động → Không khả dụng · mất kết nối",
        ], "newest first; the unchanged status wrote nothing")
        #expect(rows.allSatisfy { $0.destinationId == .googleDrive })
    }

    @Test func aStatusThatFlipsBackSoonLeavesNoRows() async throws {
        let h = try await harness()
        let now = Date()
        try h.write { db in
            for hour in 0..<5 {
                // Drive full, then the next cycle's probe resets it, then the next upload fills it again.
                let start = now.addingTimeInterval(Double(hour) * 1800)
                try DestinationRepository.setStatus(db, id: .googleDrive, status: .paused(.full), now: start)
                try DestinationRepository.setStatus(db, id: .googleDrive, status: .active, now: start.addingTimeInterval(600))
            }
            try DestinationRepository.setStatus(db, id: .googleDrive, status: .paused(.full), now: now.addingTimeInterval(9000))
        }
        #expect(try events(h, .statusChanged).count == 1, "only the status it ended in")
    }

    @Test func removingADestinationForgetsItsOpenRows() async throws {
        let h = try await harness()
        try h.write { db in
            try SyncMilestones.noteUploads(db, id: .googleDrive, count: 2, now: Date())
            #expect(try KeyValueRepository.string(db, ActivityRepository.coalesceKey("uploaded", .googleDrive)) != nil)
            try DestinationRepository.resetState(db, id: .googleDrive)
            #expect(try KeyValueRepository.string(db, ActivityRepository.coalesceKey("uploaded", .googleDrive)) == nil)
        }
    }

    @Test func uploadsOfADayShareOneRowAndTheBackfillIsAnnouncedOnce() async throws {
        let h = try await harness()
        for index in 0..<3 { await h.add(h.snapshot("old\(index)", daysAgo: 5), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.settle()
        let first = try events(h, .milestone)
        let backfill = SyncMilestones.backfillText(done: 3, deferred: 0)
        #expect(first.filter { $0.message == backfill }.count == 1)
        let uploadedBefore = try #require(first.first { $0.message != backfill })

        await h.add(h.snapshot("new", daysAgo: 0))
        await h.settle()
        let second = try events(h, .milestone)
        #expect(second.filter { $0.message == backfill }.count == 1, "announced once")
        let uploadRows = second.filter { $0.message != backfill }
        #expect(uploadRows.count == 1, "one row per destination and day")
        #expect(uploadRows[0].id == uploadedBefore.id && uploadRows[0].message != uploadedBefore.message, "the row's count grew")
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
    @Test func oneChangeIsDescribedInFull() {
        L10n.$override.withValue(.vi) {
            #expect(MovePassActivity.renameText(total: 1, from: "2026-04-26", to: "2026-04-26 Hà Nội") == "“2026-04-26” → “2026-04-26 Hà Nội”")
            #expect(MovePassActivity.moveText(total: 1, folder: "2026-04-27") == "Đã chuyển 1 file vào “2026-04-27”")
            #expect(MovePassActivity.renameText(total: 12000, from: "a", to: "b") == "Đã đổi tên 12.000 thư mục, gần nhất “a” → “b”")
        }
    }

    @Test func passesWithinAnHourGrowOneRowPerKind() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        let start = Date()
        var first = MovePassActivity()
        first.renamed(from: "2026-04-26", to: "2026-04-26 Hà Nội")
        first.moved(into: "2026-04-27")
        var second = MovePassActivity()
        second.renamed(from: "2026-04-28", to: "2026-04-28 Huế")
        try L10n.$override.withValue(.en) {
            try h.write { db in
                try first.write(db, destinationId: .googleDrive, now: start)
                try second.write(db, destinationId: .googleDrive, now: start.addingTimeInterval(600))
                try second.write(db, destinationId: .googleDrive, now: start.addingTimeInterval(2 * 3600))
            }
        }
        let rows = try h.read { db in try ActivityRepository.recent(db) }
        #expect(rows.filter { $0.kind == .moved }.map(\.message) == ["Moved 1 file into “2026-04-27”"])
        #expect(rows.filter { $0.kind == .renamed }.map(\.message) == [
            "“2026-04-28” → “2026-04-28 Huế”",
            "Renamed 2 folders, latest “2026-04-28” → “2026-04-28 Huế”",
        ], "a pass after the hour opens a new row")
    }
}
