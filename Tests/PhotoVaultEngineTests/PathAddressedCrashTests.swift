import Foundation
import PhotoVaultCore
import PhotoVaultLocal
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// A local / NAS destination is addressed by path: the path about to be written is saved before the
/// first byte, so a crash between the write and the completion neither duplicates nor skips the file.
@Suite struct PathAddressedCrashTests {
    private let editedDescriptor = ResourceDescriptor(type: .fullSizePhoto, uti: "public.jpeg", originalFilename: "FullSizeRender.JPG", isRaw: false)

    private func harness() async throws -> (Harness, URL) {
        let h = try await Harness.organized { $0.maxConcurrentUploadsPerDestination = 1 }
        try await h.withoutSidecarsAndViews()
        let (_, root, _) = try await h.useRealLocal()
        try h.addNAS(scope: .full)
        return (h, root)
    }

    private func media(_ root: URL) -> [String: Int] {
        treeListing(root).filter { !$0.key.hasPrefix(".photovault") && !$0.key.hasSuffix(".json") && !$0.key.hasSuffix(".xmp") }
    }

    private func recover(_ h: Harness) async throws {
        try await h.restart()
        try await h.coordinator.start()
        await h.settle(rounds: 6)
    }

    private func edit(_ h: Harness, _ id: String, version: Int) async {
        // The gate looks at the modification date: every edit happens later than the one before.
        h.clock.advance(by: 60)
        await h.fakePhotos.setAdjustmentHash("h\(version)", for: id)
        var snapshot = h.snapshot(id, daysAgo: 3, extra: [editedDescriptor])
        snapshot.hasAdjustments = true
        snapshot.modificationDate = h.clock.now.addingTimeInterval(-5)
        await h.fakePhotos.update(snapshot, resources: [.fullSizePhoto: Data("edit-\(version)".utf8)])
    }

    private func edited(_ root: URL) -> [String] { media(root).keys.filter { $0.contains("(edited)") }.sorted() }

    @Test func theIntentIsSavedWithTheJobStartAndRemovedWhenTheJobIsDone() async throws {
        let (h, _) = try await harness()
        await h.add(h.snapshot("a", daysAgo: 3), recordChange: false)
        try await h.baseline(h.nasId)
        h.injector.arm(.afterStartUpload)
        await h.run()
        let job = try #require(try h.jobs(.uploading).first)
        let jobId = try #require(job.id)
        let intent = try #require(try h.read { db in try UploadIntentRepository.fetch(db, jobId: jobId) })
        #expect(intent.destinationId == h.nasId && intent.remotePath.hasSuffix(".HEIC") && !intent.contentSha256.isEmpty)
        #expect(job.remoteId == nil, "the job does not claim a file before one exists")
        try await recover(h)
        #expect(try h.jobs(.done).count == 1)
        #expect(try h.read { db in try UploadIntentRepository.fetch(db, jobId: jobId) } == nil)
    }

    @Test func aDayPromotedBetweenTheCrashAndTheRetryDoesNotLeaveACopyBehind() async throws {
        let (h, root) = try await harness()
        await h.add(h.snapshot("d", daysAgo: 1), recordChange: false)
        try await h.baseline(h.nasId)
        let created = try #require(await h.fakePhotos.snapshotCreation("d"))
        let day = ArchiveDay(date: created, timeZone: utc)
        h.injector.arm(.afterUploadBeforeCommit)
        await h.run()
        #expect(media(root).count == 1, "the file is already at the destination")
        try h.write { db in _ = try DayStatRepository.promote(db, day: day, now: h.clock.now) }
        try await recover(h)
        let files = media(root)
        #expect(files.count == 1, "one file, not one per folder: \(files.keys.sorted())")
        #expect(files.keys.allSatisfy { $0.contains("/\(day)/") }, "and the move worker put it in the day folder")
        #expect(try h.jobs().allSatisfy { $0.state == .done })
    }

    @Test func anEditedFileWrittenBeforeTheCrashIsReplacedByTheNewerEditNotSkipped() async throws {
        let (h, root) = try await harness()
        await h.add(h.snapshot("a", daysAgo: 3), recordChange: false)
        try await h.baseline(h.nasId)
        await h.settle()
        await edit(h, "a", version: 1)
        h.injector.arm(.afterUploadBeforeCommit)
        await h.run()
        let path = try #require(edited(root).first)
        #expect(try Data(contentsOf: root.appendingPathComponent(path)) == Data("edit-1".utf8))

        await edit(h, "a", version: 2)
        try await recover(h)
        #expect(edited(root) == [path], "still one edited file")
        #expect(try Data(contentsOf: root.appendingPathComponent(path)) == Data("edit-2".utf8), "the newer edit was delivered")
        let job = try #require(try h.jobs().first { $0.resType == .fullSizePhoto })
        #expect(job.state == .done && job.doneGen == job.targetGen)
        #expect(try h.jobs(.skipped).isEmpty)
    }

    @Test func aRefreshThatReplacedTheFileBeforeTheCrashIsNotTakenForAForeignChange() async throws {
        let (h, root) = try await harness()
        await h.add(h.snapshot("a", daysAgo: 3), recordChange: false)
        try await h.baseline(h.nasId)
        await h.settle()
        await edit(h, "a", version: 1)
        await h.settle()
        let path = try #require(edited(root).first)

        await edit(h, "a", version: 2)
        h.injector.arm(.afterUploadBeforeCommit)
        await h.run()
        #expect(try Data(contentsOf: root.appendingPathComponent(path)) == Data("edit-2".utf8), "replaced, but the database still says edit-1")

        await edit(h, "a", version: 3)
        try await recover(h)
        #expect(try Data(contentsOf: root.appendingPathComponent(path)) == Data("edit-3".utf8))
        let job = try #require(try h.jobs().first { $0.resType == .fullSizePhoto })
        #expect(job.state == .done && job.doneGen == job.targetGen)
        #expect(try h.jobs(.skipped).isEmpty)
    }

    @Test func aForeignFileAtThePlannedPathIsNeverOverwrittenAndTheJobStillCompletes() async throws {
        let (h, root) = try await harness()
        await h.add(h.snapshot("a", daysAgo: 3), recordChange: false)
        try await h.baseline(h.nasId)
        h.injector.arm(.afterStartUpload)
        await h.run()
        let job = try #require(try h.jobs(.uploading).first)
        let jobId = try #require(job.id)
        let intent = try #require(try h.read { db in try UploadIntentRepository.fetch(db, jobId: jobId) })
        let foreign = root.appendingPathComponent(intent.remotePath)
        try Data("the owner's own file".utf8).write(to: foreign)

        try await recover(h)
        #expect(try Data(contentsOf: foreign) == Data("the owner's own file".utf8), "never touched")
        #expect(media(root).count == 2, "ours took a conflict name beside it: \(media(root).keys.sorted())")
        #expect(try h.jobs(.done).count == 1)
    }
}
