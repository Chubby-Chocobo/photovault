import Foundation
import GRDB
import PhotoVaultCore
import Testing
@testable import PhotoVaultStore

@Suite struct TransferHistoryQueryTests {
    typealias F = HistoryFixture
    let nas = DestinationID.local()

    /// Five uploaded photos a minute apart (newest last), one RAW, one video, one deleted from the library,
    /// one sent to the NAS, and one failure.
    private func library() throws -> Store {
        let store = try Store.inMemory()
        try store.write { db in
            let names = ["Ảnh biển.HEIC", "IMG_0002.HEIC", "DSC_0003.ARW", "MOV_0004.MOV", "IMG_0005.HEIC"]
            for (index, name) in names.enumerated() {
                let key = try F.file(
                    db, "f\(index)", name: name, size: Int64(100 * (index + 1)), media: index == 3 ? .video : .image, raw: index == 2,
                    created: t0.addingTimeInterval(Double(index) * 86_400), deleted: index == 4 ? t0 : nil)
                try JobRepository.upsert(db, desired: desired(F.drive, key), now: t0)
                try F.upload(db, F.identity(key), at: t0.addingTimeInterval(Double(index) * 60))
            }
            let nasFile = try F.file(db, "n", name: "IMG_NAS.HEIC")
            try JobRepository.upsert(db, desired: desired(nas, nasFile), now: t0)
            try F.upload(db, F.identity(nasFile, .photo, nas), at: t0.addingTimeInterval(600))
            let failed = try F.file(db, "x", name: "IMG_FAIL.HEIC")
            try JobRepository.upsert(db, desired: desired(F.drive, failed), now: t0)
            try F.failForGood(db, F.identity(failed), at: t0.addingTimeInterval(700))
        }
        return store
    }

    private func names(_ store: Store, _ filter: TransferEventFilter) throws -> [String] {
        try store.read { db in try HistoryRepository.events(db, filter: filter).map(\.fileName) }
    }

    @Test func pagesWalkNewestFirstWithoutGapsOrRepeats() throws {
        let store = try library()
        var seen: [Int64] = []
        var cursor: HistoryCursor?
        repeat {
            let page = try store.read { db in try HistoryRepository.events(db, filter: TransferEventFilter(), after: cursor, limit: 2) }
            seen += page.map(\.id)
            cursor = page.count == 2 ? page.last?.cursor : nil
        } while cursor != nil
        let all = try store.read { db in try HistoryRepository.events(db, filter: TransferEventFilter()) }
        #expect(seen == all.map(\.id))
        #expect(all.count == 7)
        #expect(all.first?.fileName == "IMG_FAIL.HEIC")
        #expect(all.first?.outcome == .failed && all.first?.reason == .uploadFailures)
    }

    @Test func rowsOfTheSameSecondStillPageInOrder() throws {
        let store = try Store.inMemory()
        try store.write { db in
            for index in 0..<5 {
                let key = try F.file(db, "s\(index)")
                try JobRepository.upsert(db, desired: desired(F.drive, key), now: t0)
                try F.upload(db, F.identity(key), at: t0)
            }
        }
        let first = try store.read { db in try HistoryRepository.events(db, filter: TransferEventFilter(), limit: 2) }
        let second = try store.read { db in try HistoryRepository.events(db, filter: TransferEventFilter(), after: first.last?.cursor, limit: 10) }
        #expect(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
        #expect(first.count + second.count == 5)
    }

    @Test func filtersNarrowTheList() throws {
        let store = try library()
        #expect(try names(store, TransferEventFilter(search: "anh bien")) == ["Ảnh biển.HEIC"])
        #expect(try names(store, TransferEventFilter(search: "  img_000 ")) == ["IMG_0005.HEIC", "IMG_0002.HEIC"])
        #expect(try names(store, TransferEventFilter(destinationId: nas)) == ["IMG_NAS.HEIC"])
        #expect(try names(store, TransferEventFilter(outcomes: [.failed])) == ["IMG_FAIL.HEIC"])
        #expect(try names(store, TransferEventFilter(media: .raw)) == ["DSC_0003.ARW"])
        #expect(try names(store, TransferEventFilter(media: .video)) == ["MOV_0004.MOV"])
        #expect(try names(store, TransferEventFilter(media: .photo)).contains("DSC_0003.ARW") == false)
        #expect(try names(store, TransferEventFilter(deletedFromLibraryOnly: true)) == ["IMG_0005.HEIC"])
        #expect(try names(store, TransferEventFilter(from: t0.addingTimeInterval(60), until: t0.addingTimeInterval(180)))
            == ["DSC_0003.ARW", "IMG_0002.HEIC"])
        #expect(try names(store, TransferEventFilter(
            outcomes: [.uploaded], capturedFrom: t0.addingTimeInterval(86_400), capturedUntil: t0.addingTimeInterval(3 * 86_400)))
            == ["DSC_0003.ARW", "IMG_0002.HEIC"])
    }

    @Test func aRunListsOnlyItsOwnFiles() throws {
        let store = try library()
        let runId = try store.write { db in
            let key = try F.file(db, "old", name: "IMG_OLD.HEIC")
            try JobRepository.upsert(db, desired: desired(F.drive, key, origin: .backfill), now: t0)
            try F.upload(db, F.identity(key), at: t0)
            return try #require(try JobRepository.fetch(db, identity: F.identity(key))?.backfillRunId)
        }
        #expect(try names(store, TransferEventFilter(scope: .run(runId))) == ["IMG_OLD.HEIC"])
    }

    @Test func statusesShowEveryDestinationWithTheLatestCheck() throws {
        let store = try library()
        try store.write { db in
            let key = AssetKey.local("f1")
            try JobRepository.upsert(db, desired: desired(nas, key), now: t0)
            try IntegrityCheckRepository.record(db, identity: F.identity(key), result: .hashVerified, at: t0)
            let statuses = try HistoryRepository.statuses(db, assetKey: key)
            #expect(statuses.count == 2)
            let drive = try #require(statuses.first { $0.destinationId == F.drive })
            #expect(drive.state == .done && drive.checkResult == .hashVerified && drive.checkedAt == t0)
            #expect(statuses.first { $0.destinationId == nas }?.state == .pending)
        }
    }

    @Test func timelineSumsUploadsPerQuarterHourInUTC() throws {
        let store = try library()
        let slots = try store.read { db in
            try HistoryRepository.timeline(db, from: t0.addingTimeInterval(-3_600), until: t0.addingTimeInterval(3_600))
        }
        let files = slots.map(\.files).reduce(0, +)
        let bytes = slots.map(\.bytes).reduce(0, +)
        #expect(files == 6)
        #expect(bytes == 2_500)
        let photosOnly = try store.write { db in
            let key = try F.file(db, "imp", source: SourceID.folder())
            try JobRepository.upsert(db, desired: desired(F.drive, key), now: t0)
            try F.upload(db, F.identity(key), at: t0)
            return try HistoryRepository.timeline(db, from: t0.addingTimeInterval(-3_600), until: t0.addingTimeInterval(3_600), sourceId: .photos)
        }
        #expect(photosOnly.map(\.files).reduce(0, +) == 6, "an import's uploads are not Photos uploads")
        for slot in slots {
            #expect(Int(slot.start.timeIntervalSince1970) % 900 == 0)
        }
    }

    @Test func importItemsFilterByStateAndPathAndNameTheDuplicate() throws {
        let store = try Store.inMemory()
        let source = SourceID.folder()
        try store.write { db in
            let kept = try F.file(db, "kept", name: "IMG_KEPT.HEIC", created: t0)
            try SourceRepository.insert(db, SourceRecord(id: source, kind: .localFolder, mode: .oneTime, displayName: "Trip", status: .completed, createdAt: t0))
            try ImportItemRepository.insertIgnoring(db, [
                ImportItem(sourceId: source, relativePath: "a/Ảnh 1.jpg", groupKey: "a/1", uti: "public.jpeg", sizeBytes: 10, state: .imported),
                ImportItem(sourceId: source, relativePath: "b/copy.jpg", groupKey: "b/c", uti: "public.jpeg", sizeBytes: 20, state: .duplicate, assetKey: kept),
                ImportItem(sourceId: source, relativePath: "c/broken.jpg", groupKey: "c/b", uti: "public.jpeg", sizeBytes: 30, state: .failed, reason: "read"),
            ])
            let all = try ImportHistoryRepository.items(db, filter: ImportItemFilter(sourceId: source))
            #expect(all.map(\.relativePath) == ["a/Ảnh 1.jpg", "b/copy.jpg", "c/broken.jpg"])
            let duplicate = try #require(all.first { $0.state == .duplicate })
            #expect(duplicate.duplicateOfName == "IMG_KEPT.HEIC" && duplicate.duplicateOfCapturedAt == t0)
            #expect(try ImportHistoryRepository.items(db, filter: ImportItemFilter(sourceId: source, states: [.failed])).map(\.reason) == ["read"])
            #expect(try ImportHistoryRepository.items(db, filter: ImportItemFilter(sourceId: source, search: "anh")).count == 1)
            #expect(try ImportHistoryRepository.items(db, filter: ImportItemFilter(sourceId: source), after: "a/Ảnh 1.jpg", limit: 1).map(\.relativePath) == ["b/copy.jpg"])
            let summary = try #require(try ImportHistoryRepository.imports(db).first)
            #expect(summary.totals[.duplicate] == OutcomeTotal(files: 1, bytes: 20))
            #expect(summary.totals[.failed] == OutcomeTotal(files: 1, bytes: 30))
        }
    }
}
