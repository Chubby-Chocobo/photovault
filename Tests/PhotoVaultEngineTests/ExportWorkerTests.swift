import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    var all: [String] { lock.withLock { items } }
}

@Suite struct ExportWorkerTests {
    @Test func incrementalBeforeBackfillNewestFirstAndPrimaryBeforeSecondary() async throws {
        let h = try await Harness { $0.maxConcurrentExports = 1 }
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("oldA", daysAgo: 20), recordChange: false)
        await h.add(h.snapshot("oldB", daysAgo: 5), recordChange: false)
        try await h.baseline(.googleDrive)
        h.clock.advance(by: 60)
        var live = h.snapshot("liveN", daysAgo: 0.2, subtypes: .photoLive)
        live.resources.insert(ResourceDescriptor(type: .pairedVideo, uti: "com.apple.quicktime-movie", originalFilename: "IMG_liveN.MOV", isRaw: false), at: 0)
        await h.add(live)
        await h.add(h.snapshot("plainN", daysAgo: 0.1))
        let order = OrderLog()
        h.photos.beforeExport = { id, type, _ in order.add("\(id)/\(type.rawValue)") }
        await h.run()
        // photo (type 1) is the primary of a Live Photo; the paired video (9) follows it.
        #expect(order.all == ["plainN/1", "liveN/1", "liveN/9", "oldB/1", "oldA/1"], "\(order.all)")
    }

    @Test func atMostTwoExportsRunAtOnce() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        for i in 0..<8 { await h.add(h.snapshot("e\(i)", daysAgo: Double(i)), recordChange: true) }
        h.photos.beforeExport = { _, _, _ in for _ in 0..<20 { await Task.yield() } }
        await h.run()
        #expect(h.photos.maxConcurrent <= 2)
        #expect(await h.drive.files.count == 8)
    }

    @Test func eachResourceIsExportedOnceForAllDestinations() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try h.addNAS(scope: .full)
        await h.add(h.snapshot("one"), recordChange: false)
        try await h.baseline(.googleDrive, h.nasId)
        await h.run()
        #expect(await h.fakePhotos.exports(of: "one") == 1)
        #expect(await h.drive.files.count == 1)
        #expect(await h.nas.files.count == 1)
    }

    @Test func exportStoresHashesSizeAndCameraMetadata() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("meta"), recordChange: false)
        try await h.baseline(.googleDrive)
        _ = try await h.coordinator.scanner.run()
        try await h.coordinator.finalize.runAfterScan()
        _ = try await h.coordinator.classifier.runPass()
        _ = try await h.coordinator.exporter.runPass()
        let resource = try #require(try h.read { db in try ResourceRepository.fetch(db, key: .local("meta"), type: .photo) })
        let expected = TestFiles.hashes(of: Data("meta/1".utf8))
        #expect(resource.stagingState == .ready)
        #expect(resource.md5 == expected.md5 && resource.sha256 == expected.sha256)
        #expect(resource.sizeBytes == 6 && resource.exportCount == 1 && resource.exportAttempts == 0)
        let asset = try #require(try h.asset(.local("meta")))
        #expect(asset.cameraMake == "Apple" && asset.cameraModel == "iPhone 15" && asset.lensModel == "Wide")
        #expect(resource.stagingPath.map { FileManager.default.fileExists(atPath: $0) } == true)
    }

    @Test func nothingIsExportedForAnAssetWithoutPlacement() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("unplaced"), recordChange: false)
        try await h.baseline(.googleDrive)
        _ = try await h.coordinator.scanner.run()
        try await h.coordinator.finalize.runAfterScan()
        let result = try await h.coordinator.exporter.runPass()
        #expect(result.exported == 0)
        #expect(await h.fakePhotos.exportCount.isEmpty, "provisional assets are classified first")
    }

    @Test func backfillWaitsForTheScanToComplete() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("bf", subtypes: .photoScreenshot), recordChange: false)
        try await h.baseline(.googleDrive)
        _ = try await h.coordinator.scanner.run()
        try await h.coordinator.finalize.runAfterScan()
        try h.write { db in try KeyValueRepository.setScanState(db, .running) }
        var result = try await h.coordinator.exporter.runPass()
        #expect(result.exported == 0)
        try h.write { db in try KeyValueRepository.setScanState(db, .complete) }
        result = try await h.coordinator.exporter.runPass()
        #expect(result.exported == 1)
    }

    @Test func exportErrorsBackOffDeferAfterEightAndRecoverAfterADay() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        await h.add(h.snapshot("flaky"))
        await h.fakePhotos.failExports(of: "flaky", times: 9)
        await h.run()
        var resource = try #require(try h.read { db in try ResourceRepository.fetch(db, key: .local("flaky"), type: .photo) })
        #expect(resource.exportAttempts == 1)
        let due = try #require(resource.nextExportAttemptAt)
        #expect(due > h.clock.now)
        await h.run()
        resource = try #require(try h.read { db in try ResourceRepository.fetch(db, key: .local("flaky"), type: .photo) })
        #expect(resource.exportAttempts == 1, "not retried before the backoff elapsed")
        for _ in 0..<9 {
            h.clock.advance(by: 3600)
            await h.run()
        }
        let job = try #require(try h.jobs().first)
        #expect(job.state == .deferred && job.stateReason == .exportFailures)
        #expect(job.attempts == 0, "export errors use the resource counter, not the job's")
        h.clock.advance(by: 25 * 3600)
        await h.run()
        #expect(try h.jobs().first?.state == .done)
        #expect(await h.drive.files.count == 1)
    }

    @Test func missingResourceSkipsTheJobWithoutRetrying() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        await h.add(h.snapshot("gone"))
        h.photos.beforeExport = { id, type, _ in throw PhotosSourceError.resourceNotFound(localId: id, type: type) }
        await h.run()
        let job = try #require(try h.jobs().first)
        #expect(job.state == .skipped && job.stateReason == .resourceMissing)
        let resource = try #require(try h.read { db in try ResourceRepository.fetch(db, key: .local("gone"), type: .photo) })
        #expect(resource.stagingState == .none && resource.exportAttempts == 0)
    }

    @Test func sizeRuleCancelsTheStreamEarlyWhenEveryDestinationExceedsItsCap() async throws {
        let h = try await Harness { $0.exportCheckpointBytes = 1 }
        var rules = DestinationRules()
        rules.skipLargerThanBytes = 100
        try h.addDrive(scope: .full, rules: rules)
        try h.addNAS(scope: .full, rules: rules)
        try await h.baseline(.googleDrive, h.nasId)
        await h.fakePhotos.add(h.snapshot("big"), resources: [.photo: Data(repeating: 1, count: 1_000)], header: camera)
        await h.run()
        let jobs = try h.jobs()
        #expect(jobs.count == 2 && jobs.allSatisfy { $0.state == .skipped && $0.stateReason == .tooLargeForRule })
        #expect(await h.fakePhotos.exports(of: "big") == 0, "the stream was cancelled before it completed")
        #expect(h.stagingFiles().isEmpty)
        let resource = try #require(try h.read { db in try ResourceRepository.fetch(db, key: .local("big"), type: .photo) })
        #expect(resource.stagingState == .none && resource.exportAttempts == 0 && resource.diskCancelCount == 0)
    }

    @Test func sizeRuleSkipsOnlyTheDestinationWhoseCapIsExceeded() async throws {
        let h = try await Harness { $0.exportCheckpointBytes = 1 }
        var capped = DestinationRules()
        capped.skipLargerThanBytes = 100
        try h.addDrive(scope: .full, rules: capped)
        try h.addNAS(scope: .full)
        try await h.baseline(.googleDrive, h.nasId)
        await h.fakePhotos.add(h.snapshot("big"), resources: [.photo: Data(repeating: 1, count: 1_000)], header: camera)
        await h.run()
        #expect(await h.drive.files.isEmpty)
        #expect(await h.nas.files.count == 1)
        #expect(try h.jobs(.skipped, destination: .googleDrive).first?.stateReason == .tooLargeForRule)
        #expect(try h.jobs(.done, destination: h.nasId).count == 1)
    }

    @Test func classificationKeepsACompletelyDownloadedFileAsStaging() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("full"), recordChange: false)
        try await h.baseline(.googleDrive)
        let payload = Data("whole file".utf8)
        let hashes = TestFiles.hashes(of: payload)
        h.photos.headerOverride = { _, spill, _ in
            try payload.write(to: spill)
            return HeaderResult(metadata: camera, isConclusive: true,
                                completeFile: ExportedFile(url: spill, size: Int64(payload.count), md5: hashes.md5, sha256: hashes.sha256))
        }
        _ = try await h.coordinator.scanner.run()
        try await h.coordinator.finalize.runAfterScan()
        let classified = try await h.coordinator.classifier.runPass()
        #expect(classified.classified == 1)
        let resource = try #require(try h.read { db in try ResourceRepository.fetch(db, key: .local("full"), type: .photo) })
        #expect(resource.stagingState == .ready && resource.sha256 == hashes.sha256)
        await h.run()
        #expect(await h.fakePhotos.exports(of: "full") == 0, "the downloaded file was uploaded, no second download")
        #expect(await h.drive.files.first?.content?.sha256 == hashes.sha256)
    }

    @Test func inconclusiveHeaderLeavesTheAssetProvisionalAndRetriesLater() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("unsure"), recordChange: false)
        try await h.baseline(.googleDrive)
        h.photos.headerOverride = { _, _, _ in HeaderResult(metadata: nil, isConclusive: false, completeFile: nil) }
        await h.run()
        #expect(try h.asset(.local("unsure"))?.categoryProvisional == true)
        #expect(await h.drive.files.isEmpty)
        h.photos.headerOverride = nil
        h.clock.advance(by: 3600)
        await h.run()
        #expect(await h.drive.files.count == 1)
    }
}
