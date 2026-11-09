import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// Error handling strictly by `ErrorClassifier` (spec 8.14) and the reliability scenarios built on it.
@Suite struct UploadErrorTests {
    private func oneJob(_ h: Harness, scope: ScopeMode = .full) async throws {
        try h.addDrive(scope: scope)
        await h.add(h.snapshot("a", daysAgo: 1), recordChange: false)
        try await h.baseline(.googleDrive)
    }

    @Test func destinationLevelErrorSetsStatusAndNeverTouchesAttempts() async throws {
        let h = try await Harness()
        try await oneJob(h)
        await h.drive.failNext(.upload, with: .quotaExceeded)
        await h.run()
        let record = try #require(try h.read { db in try DestinationRepository.fetch(db, id: .googleDrive) })
        #expect(record.status == .paused(.full))
        let job = try #require(try h.jobs().first)
        #expect(job.state == .pending && job.attempts == 0 && job.nextAttemptAt == nil)
        #expect(job.remoteId != nil, "the reserved id survives")
        let events = try h.read { db in try ActivityRepository.recent(db) }
        #expect(events.contains { $0.kind == .statusChanged })
    }

    @Test(arguments: [
        (DestinationError.unauthorized, DestinationStatus.error(.reauthRequired)),
        (.reauthRequired, .error(.reauthRequired)),
        (.offline, .unavailable(.offline)),
        (.bookmarkInvalid, .unavailable(.bookmarkInvalid)),
        (.dailyCapReached, .paused(.dailyCapReached)),
        (.rootMissing, .paused(.rootMissing)),
        (.rootTrashed, .paused(.rootTrashed)),
        (.folderTrashed(logicalPath: "x"), .paused(.folderTrashed)),
    ])
    func destinationErrorsMapToStatuses(_ error: DestinationError, _ status: DestinationStatus) async throws {
        let h = try await Harness()
        try await oneJob(h)
        await h.drive.failNext(.upload, with: error)
        await h.run()
        let record = try #require(try h.read { db in try DestinationRepository.fetch(db, id: .googleDrive) })
        #expect(record.status == status)
        #expect(try h.jobs().first?.attempts == 0)
        #expect(try h.jobs().first?.state == .pending)
    }

    @Test func nothingUploadsWhileTheDestinationIsNotActiveAndResumesWhenItIsBack() async throws {
        let h = try await Harness()
        try await oneJob(h)
        await h.drive.setStatus(.unavailable(.offline))
        await h.run()
        #expect(await h.drive.files.isEmpty)
        #expect(try h.read { db in try DestinationRepository.fetch(db, id: .googleDrive)?.status } == .unavailable(.offline))
        await h.drive.setStatus(.active)
        await h.run()
        #expect(await h.drive.files.count == 1)
        #expect(try h.read { db in try DestinationRepository.fetch(db, id: .googleDrive)?.status } == .active)
    }

    /// One upload at a time is the order where folders are still missing when the folder and
    /// reserve errors arrive; two at a time is the default.
    @Test(arguments: [1, 2])
    func t18FlakyDestinationNeverDefersOrSkipsAnyJob(concurrency: Int) async throws {
        let h = try await Harness { $0.maxConcurrentUploadsPerDestination = concurrency }
        try h.addDrive(scope: .full)
        for i in 0..<6 { await h.add(h.snapshot("f\(i)", daysAgo: Double(i + 1)), recordChange: false) }
        try await h.baseline(.googleDrive)
        for round in 0..<14 {
            switch round % 5 {
            case 0: await h.drive.failNext(.upload, with: .offline)
            case 1: await h.drive.failNext(.reserve, with: .server(status: 503), times: 3)
            case 2: await h.drive.failNext(.upload, with: .rateLimited(retryAfter: 1), times: 2)
            case 3: await h.drive.failNext(.ensureFolder, with: .transient(reason: "reset"), times: 2)
            default: await h.drive.failNext(.probe, with: .offline)
            }
            await h.run()
            h.clock.advance(by: 3600)
            let bad = try h.jobs().filter { $0.state == .deferred || $0.state == .skipped }
            #expect(bad.isEmpty, "round \(round): \(bad.map(\.state))")
            #expect(try h.jobs().allSatisfy { $0.attempts == 0 }, "round \(round): destination errors never count")
        }
        // Once the destination behaves, everything finishes (one at a time takes more cycles).
        for _ in 0..<8 where await h.drive.files.count < 6 {
            await h.run()
            h.clock.advance(by: 3600)
        }
        #expect(await h.drive.files.count == 6)
        #expect(try h.jobs().allSatisfy { $0.state == .done })
        #expect(await h.drive.contractViolations.isEmpty)
    }

    @Test func transientErrorsRetryInsideThePassWithoutCostingAnAttempt() async throws {
        let h = try await Harness()
        try await oneJob(h)
        await h.drive.failNext(.upload, with: .transient(reason: "reset"), times: 3)
        await h.run()
        #expect(await h.drive.files.count == 1)
        #expect(try h.jobs().first?.attempts == 0)
        #expect(await h.drive.operationLog.filter { $0 == .upload }.count == 4)
    }

    @Test(arguments: [FakeDestination.Operation.ensureFolder, .reserve])
    func transientErrorsBeforeTheUploadAlsoRetryWithoutCostingAnAttempt(_ operation: FakeDestination.Operation) async throws {
        let h = try await Harness()
        try await oneJob(h)
        await h.drive.failNext(operation, with: .transient(reason: "reset"), times: 2)
        await h.run()
        #expect(await h.drive.files.count == 1)
        #expect(try h.jobs().first?.attempts == 0)
    }

    @Test func repeatedServerErrorsBackTheWholeDestinationOff() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        for i in 0..<4 { await h.add(h.snapshot("s\(i)", daysAgo: Double(i + 1)), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.drive.failNext(.upload, with: .server(status: 500), times: 40)
        await h.run()
        let uploadCalls = await h.drive.operationLog.filter { $0 == .upload }.count
        #expect(uploadCalls < 12, "the destination backs off instead of hammering: \(uploadCalls) calls")
        #expect(try h.jobs().allSatisfy { $0.attempts == 0 && $0.state == .pending })
        // Within the backoff window the next cycle does not call the destination at all.
        await h.run()
        #expect(await h.drive.operationLog.filter { $0 == .upload }.count == uploadCalls)
    }

    @Test func itemErrorsCountAttemptsDeferAfterEightAndComeBackAfterADay() async throws {
        let h = try await Harness()
        try await oneJob(h)
        await h.drive.failNext(.upload, with: .itemRejected(reason: "bad"), times: 9)
        for _ in 0..<9 {
            await h.run()
            h.clock.advance(by: 3600)
        }
        let job = try #require(try h.jobs().first)
        #expect(job.state == .deferred && job.stateReason == .uploadFailures)
        #expect(job.deferredSince != nil)
        h.clock.advance(by: 25 * 3600)
        await h.run()
        #expect(try h.jobs().first?.state == .done)
        #expect(await h.drive.files.count == 1)
    }

    @Test func deferredForThirtyDaysBecomesSkipped() async throws {
        let h = try await Harness()
        try await oneJob(h)
        await h.drive.failNext(.upload, with: .itemRejected(reason: "bad"), times: 400)
        for _ in 0..<9 {
            await h.run()
            h.clock.advance(by: 3600)
        }
        #expect(try h.jobs().first?.state == .deferred)
        let since = try #require(try h.jobs().first?.deferredSince)
        h.clock.set(since.addingTimeInterval(31 * 86_400))
        await h.run()
        #expect(try h.jobs().first?.state == .skipped)
        #expect(try h.jobs().first?.stateReason == .deferredTooLong)
    }

    @Test func foreignFileAtALocalDestinationSkipsTheJobImmediately() async throws {
        let h = try await Harness()
        try h.addNAS(scope: .full)
        await h.add(h.snapshot("z", daysAgo: 1), recordChange: false)
        try await h.baseline(.local(UUID(uuidString: h.nasId.rawValue.replacingOccurrences(of: "local-", with: ""))!))
        await h.nas.failNext(.upload, with: .foreignFile)
        await h.run()
        let job = try #require(try h.jobs().first)
        #expect(job.state == .skipped && job.stateReason == .foreignFile)
    }

    @Test func checksumMismatchIsRepairedInPlaceOnTheSameId() async throws {
        let h = try await Harness()
        try await oneJob(h)
        let wrapper = WrappedDestination(h.drive)
        wrapper.corrupt(uploads: 1, replaces: 0)
        await h.useWrapped(wrapper)
        await h.run()
        let files = await h.drive.files
        #expect(files.count == 1, "repaired in place, never a second file")
        let job = try #require(try h.jobs().first)
        #expect(job.state == .done && job.mismatchCount == 0)
        #expect(await h.drive.operationLog.contains(.replace))
        #expect(job.remoteId == files[0].id)
    }

    @Test func persistentChecksumMismatchEndsSkippedKeepingTheRemoteId() async throws {
        let h = try await Harness()
        try await oneJob(h)
        let wrapper = WrappedDestination(h.drive)
        wrapper.corrupt(uploads: 1, replaces: 100)
        await h.useWrapped(wrapper)
        await h.run()
        let job = try #require(try h.jobs().first)
        #expect(job.state == .skipped && job.stateReason == .checksumMismatch)
        #expect(job.remoteId != nil)
        #expect(await h.drive.files.count == 1)
        #expect(await h.drive.operationLog.filter { $0 == .replace }.count == 3)
    }

    @Test func destinationReportedChecksumMismatchAlsoReplacesInPlace() async throws {
        let h = try await Harness()
        try await oneJob(h)
        // Reported by the destination itself before any effect: the repair finds nothing to replace
        // and the job simply retries as an item error.
        await h.drive.failNext(.upload, with: .checksumMismatch(expected: "a", actual: "b"))
        await h.run()
        h.clock.advance(by: 3600)
        await h.run()
        #expect(await h.drive.files.count == 1)
        #expect(try h.jobs().first?.state == .done)
    }

    @Test func folderGoneAtTheDestinationIsRecreatedWithoutCountingAnAttempt() async throws {
        let h = try await Harness()
        try await oneJob(h)
        await h.run()
        await h.add(h.snapshot("b", daysAgo: 1), camera: true)
        // The day folder disappears behind the app's back.
        let dayPath = h.cameraDayPath(daysAgo: 1)
        let day = await h.drive.folders.first { $0.appProperties[AppPropertyKey.logical] == dayPath }
        await h.drive.externallyDelete(try #require(day?.id))
        await h.run()
        h.clock.advance(by: 3600)
        await h.run()
        let names = await h.fileNames(h.drive)
        #expect(names.contains { $0.hasSuffix("IMG_b.HEIC") })
        #expect(try h.jobs().allSatisfy { $0.attempts == 0 })
    }

    @Test func uploadsToTwoDestinationsRunConcurrentlyButNeverMoreThanTwoPerDestination() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        for i in 0..<8 { await h.add(h.snapshot("c\(i)", daysAgo: Double(i + 1)), recordChange: false) }
        try await h.baseline(.googleDrive)
        let wrapper = WrappedDestination(h.drive)
        await h.useWrapped(wrapper)
        await h.run()
        #expect(await h.drive.files.count == 8)
        #expect(wrapper.maxConcurrentUploads <= 2)
        #expect(wrapper.maxConcurrentUploads >= 1)
    }

    @Test func sameFolderIsCreatedOnceWhenUploadsRaceForIt() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        for i in 0..<6 {
            var s = h.snapshot("r\(i)")
            s.creationDate = h.clock.now.addingTimeInterval(-86_400 - Double(i))
            await h.add(s, recordChange: false)
        }
        try await h.baseline(.googleDrive)
        await h.run()
        let folders = await h.drive.folders.filter { $0.id != "root" }
        let keys = folders.map { "\($0.parentId)/\($0.name)" }
        #expect(Set(keys).count == keys.count)
        #expect(folders.count == 2, "Camera Uploads and the day, once each: \(keys)")
    }
}
