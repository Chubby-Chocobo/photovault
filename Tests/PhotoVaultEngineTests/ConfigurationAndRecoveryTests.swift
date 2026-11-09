import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

@Suite struct ConfigurationAndRecoveryTests {
    @Test func settingsAndArchiveTimeZonePersistAcrossRestarts() async throws {
        let h = try await Harness()
        try await h.update {
            $0.integrityCheckIntervalDays = 25
            $0.includeHidden = true
        }
        try await h.restart()
        let snapshot = await h.env.settings.snapshot()
        #expect(snapshot.settings.integrityCheckIntervalDays == 25 && snapshot.settings.includeHidden)
        #expect(snapshot.timeZone == utc)
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        try await h.env.settings.setArchiveTimeZone(tokyo)
        try await h.restart()
        #expect(await h.env.settings.snapshot().timeZone == tokyo)
    }

    @Test func baselineIsTakenOnceAndStampsTheDestination() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .newOnly)
        await h.add(h.snapshot("a"), recordChange: false)
        h.clock.advance(by: 100)
        try await h.baseline(.googleDrive)
        let first = try #require(try h.read { db in try DestinationRepository.fetch(db, id: .googleDrive)?.baselineAt })
        #expect(first == h.clock.now)
        let token = try h.read { db in try KeyValueRepository.data(db, KeyValueRepository.Key.baselineToken) }
        let changeToken = try h.changeToken()
        #expect(token != nil && token == changeToken)
        h.clock.advance(by: 100)
        await h.add(h.snapshot("later"))
        try await h.baseline(.googleDrive)
        #expect(try h.read { db in try DestinationRepository.fetch(db, id: .googleDrive)?.baselineAt } == first, "a second baseline changes nothing")
        #expect(try h.read { db in try KeyValueRepository.data(db, KeyValueRepository.Key.baselineToken) } == token)
    }

    @Test func interruptedUploadWhoseRemoteContentDiffersIsReplacedInPlace() async throws {
        let h = try await Harness { $0.maxConcurrentUploadsPerDestination = 1 }
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("r", daysAgo: 1), recordChange: false)
        try await h.baseline(.googleDrive)
        h.injector.arm(.afterUploadBeforeCommit)
        await h.run()
        let stuck = try #require(try h.jobs(.uploading).first)
        let id = try #require(stuck.remoteId)
        let other = try TestFiles.staged(Data("someone else".utf8), in: h.root)
        await h.drive.externallyModify(id, content: other)
        try await h.restart()
        let summary = try await h.coordinator.start()
        #expect(summary.jobsRequeued == 1 && summary.jobsCompleted == 0)
        await h.run()
        let files = await h.drive.files
        #expect(files.count == 1 && files[0].id == id, "same id, no second file")
        #expect(files[0].content?.sha256 == TestFiles.hashes(of: Data("r/1".utf8)).sha256)
        #expect(await h.drive.operationLog.contains(.replace))
        #expect(try h.jobs().allSatisfy { $0.state == .done })
    }

    @Test func sessionExpiredDuringResumeOpensANewSessionForTheSameId() async throws {
        let h = try await Harness { $0.maxConcurrentUploadsPerDestination = 1 }
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("s", daysAgo: 1), recordChange: false)
        try await h.baseline(.googleDrive)
        h.injector.arm(.afterSessionPersisted)
        await h.run()
        let reserved = try #require(try h.jobs(.uploading).first?.remoteId)
        await h.drive.expireSessions()
        try await h.restart()
        try await h.coordinator.start()
        await h.run()
        #expect(await h.drive.files.map(\.id) == [reserved])
        #expect(await h.drive.operationLog.contains(.resume))
        #expect(try h.jobs().allSatisfy { $0.state == .done })
    }

    @Test func planningExtensionsRunInsideEligibilityTransactions() async throws {
        struct Spy: JobPlanningExtension {
            let seen: SeenBox
            func plan(_ db: Database, asset: AssetRecord, destination: DestinationRecord, eligible: Bool,
                      plannedTypes: [ResourceType], context: PipelineContext) throws {
                seen.add("\(asset.assetKey.rawValue)|\(destination.id)|\(eligible)|\(plannedTypes.count)")
            }
        }
        final class SeenBox: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [String] = []
            func add(_ item: String) { lock.withLock { items.append(item) } }
            var all: [String] { lock.withLock { items } }
        }
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("x", subtypes: .photoScreenshot), recordChange: false)
        try await h.baseline(.googleDrive)
        let box = SeenBox()
        let coordinator = SyncCoordinator(env: h.env, stages: [], reconciler: nil, recoveryParticipants: [], planningExtensions: [Spy(seen: box)])
        _ = await coordinator.run(trigger: .manual)
        #expect(box.all.contains("l:x|gdrive|true|1"))
    }

    @Test func recoveryParticipantsRunAfterEngineRecovery() async throws {
        struct Participant: RecoveryParticipant {
            let flag: Flag
            func recover() async throws { flag.set() }
        }
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func set() { lock.withLock { value = true } }
            var isSet: Bool { lock.withLock { value } }
        }
        let h = try await Harness()
        let flag = Flag()
        let coordinator = SyncCoordinator(env: h.env, recoveryParticipants: [Participant(flag: flag)])
        try await coordinator.start()
        #expect(flag.isSet)
    }

    @Test func sidecarJobsAreGeneratedAndUploadedAndTheCycleTerminates() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("sc", subtypes: .photoScreenshot), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.run()
        try h.write { db in
            var job = UploadJob(destinationId: .googleDrive, assetKey: .local("sc"), resType: .sidecarJson, origin: .incremental, updatedAt: h.clock.now)
            try JobRepository.save(db, &job)
        }
        await h.run()
        #expect(try h.jobs(.pending).isEmpty, "the sidecar is generated at upload time and the cycle terminates")
        #expect(await h.drive.files.count == 2)
    }
}
