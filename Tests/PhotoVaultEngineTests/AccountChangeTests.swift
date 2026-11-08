import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// Another Google account for the same destination: checked, committed and reset inside the lane.
@Suite struct AccountChangeTests {
    private struct CommitFailed: Error {}
    private let other = DriveAccount(id: "u2", email: "b@example.com")

    private func firstLife(assets: Int = 2) async throws -> Harness {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        for index in 0..<assets { await h.add(h.snapshot("p\(index)", daysAgo: Double(index + 1)), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.settle()
        return h
    }

    @Test func aFailingCommitLeavesTheDatabaseUntouched() async throws {
        let h = try await firstLife()
        let before = try h.destinationRecord(.googleDrive)
        let jobs = try h.jobs().count
        #expect(jobs > 0)
        await #expect(throws: CommitFailed.self) {
            try await h.coordinator.changeDriveAccount(
                .googleDrive, rootId: "root", rootName: "Camera Uploads", account: other, rootHasContent: true,
                checkRootWith: h.drive, commitAccount: { throw CommitFailed() })
        }
        let after = try h.destinationRecord(.googleDrive)
        #expect(after.accountId == before.accountId && after.accountEmail == before.accountEmail)
        #expect(after.config.driveRootId == before.config.driveRootId && !after.recoveryRequired && after.status == before.status)
        #expect(try h.jobs().count == jobs, "the old knowledge is still there")
    }

    @Test func aRootThatIsNotThereNeverReachesTheCommit() async throws {
        let h = try await firstLife()
        let commits = Box(0)
        await #expect(throws: RootProblemError.stillMissing) {
            try await h.coordinator.changeDriveAccount(
                .googleDrive, rootId: "nope", rootName: "x", account: other, rootHasContent: true,
                checkRootWith: h.drive, commitAccount: { commits.mutate { $0 += 1 } })
        }
        await h.drive.externallyTrash("root")
        await #expect(throws: RootProblemError.stillTrashed) {
            try await h.coordinator.changeDriveAccount(
                .googleDrive, rootId: "root", rootName: "x", account: other, rootHasContent: true,
                checkRootWith: h.drive, commitAccount: { commits.mutate { $0 += 1 } })
        }
        #expect(commits.get() == 0)
        #expect(try h.destinationRecord(.googleDrive).accountEmail != other.email)
    }

    @Test func theCommitRunsInsideTheLaneBeforeTheResetAndNothingUploadsMeanwhile() async throws {
        let h = try await Harness { $0.maxConcurrentUploadsPerDestination = 1 }
        let wrapper = ControllableDrive(h.drive)
        await h.env.destinations.add(wrapper)
        h.overrides = [wrapper]
        try h.addDrive(scope: .full)
        for index in 0..<4 { await h.add(h.snapshot("p\(index)", daysAgo: Double(index + 1)), recordChange: false) }
        try await h.baseline(.googleDrive)
        let entered = Flag()
        wrapper.beforeUpload = {
            guard entered.takeFirst() else { return }
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
        let cycle = Task { await h.run() }
        for _ in 0..<2_000 where !entered.isSet { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(entered.isSet)

        let seen = Box<(accountBefore: String?, uploadsBefore: Int, uploadsAfter: Int)>((nil, -1, -1))
        let store = h.store
        try await h.coordinator.changeDriveAccount(
            .googleDrive, rootId: "root", rootName: "Camera Uploads", account: other, rootHasContent: false,
            checkRootWith: h.drive,
            commitAccount: {
                let account = try await store.read { db in try DestinationRepository.fetch(db, id: .googleDrive)?.accountId }
                let before = await h.drive.files.count
                try await Task.sleep(nanoseconds: 150_000_000)
                let after = await h.drive.files.count
                seen.set((account, before, after))
            })
        let observed = seen.get()
        #expect(observed.accountBefore != other.id, "the new account is not visible before the commit")
        #expect(observed.uploadsBefore >= 0 && observed.uploadsBefore == observed.uploadsAfter, "no upload started during the command")
        #expect(try h.destinationRecord(.googleDrive).accountId == other.id)
        _ = await cycle.value
    }

    @Test func aSuccessfulChangeResetsLikeAChangedRoot() async throws {
        let h = try await firstLife()
        try await h.coordinator.changeDriveAccount(
            .googleDrive, rootId: "root", rootName: "Camera Uploads", account: other, rootHasContent: true,
            checkRootWith: h.drive, commitAccount: {})
        let record = try h.destinationRecord(.googleDrive)
        #expect(record.accountEmail == other.email && record.accountId == other.id)
        #expect(record.recoveryRequired == false || record.status == .paused(.recovering))
        #expect(try h.jobs().isEmpty)
    }
}

/// First start recovers only a destination that still needs it, decided inside the lane.
@Suite struct RecoveryRequestTests {
    private func scanned() async throws -> Harness {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("a", daysAgo: 2), recordChange: false)
        try await h.baseline(.googleDrive)
        try await h.coordinator.scanner.run()
        return h
    }

    @Test func firstStartDoesNothingWhenTheDestinationDoesNotNeedRecovery() async throws {
        let h = try await scanned()
        let lists = await h.count(of: .list, on: h.drive)
        let outcome = try await h.coordinator.startRecovery(.googleDrive, onlyIfRequired: true)
        #expect(outcome == .recovered(RecoveryStats()))
        #expect(await h.count(of: .list, on: h.drive) == lists, "neither a listing nor a cycle")
    }

    @Test func firstStartRecoversADestinationThatNeedsIt() async throws {
        let h = try await scanned()
        try h.updateDestination(.googleDrive) { $0.recoveryRequired = true }
        let lists = await h.count(of: .list, on: h.drive)
        _ = try await h.coordinator.startRecovery(.googleDrive, onlyIfRequired: true)
        #expect(await h.count(of: .list, on: h.drive) > lists)
        #expect(try h.destinationRecord(.googleDrive).recoveryRequired == false)
    }

    @Test func aCycleThatRecoveredBeforeTheRequestIsNotRepeated() async throws {
        let h = try await scanned()
        try h.updateDestination(.googleDrive) { $0.recoveryRequired = true }
        _ = try await h.coordinator.hardening.recovery.recover(.googleDrive)
        let lists = await h.count(of: .list, on: h.drive)
        let outcome = try await h.coordinator.startRecovery(.googleDrive, onlyIfRequired: true)
        #expect(outcome == .recovered(RecoveryStats()))
        #expect(await h.count(of: .list, on: h.drive) == lists, "no second listing")
    }

    @Test func theOwnersRequestAlwaysRuns() async throws {
        let h = try await scanned()
        let lists = await h.count(of: .list, on: h.drive)
        _ = try await h.coordinator.startRecovery(.googleDrive)
        #expect(await h.count(of: .list, on: h.drive) > lists)
    }
}

/// A reset forgets the stored integrity result; mismatched files show once.
@Suite struct IntegrityResetTests {
    private func rottedLocal(rotted: Int) async throws -> Harness {
        let h = try await Harness()
        let (_, root, _) = try await h.useRealLocal()
        try h.addNAS(scope: .full)
        for index in 0..<3 { await h.add(h.snapshot("q\(index)", daysAgo: Double(index + 1)), recordChange: false) }
        try await h.baseline(h.nasId)
        await h.settle()
        let files = treeListing(root).keys.filter { !$0.hasPrefix(".photovault") && !$0.hasSuffix(".json") && !$0.hasSuffix(".xmp") }.sorted()
        #expect(files.count == 3)
        for (offset, name) in files.enumerated() {
            let url = root.appendingPathComponent(name)
            if offset < rotted {
                try Data("x".utf8).write(to: url)
            } else {
                try FileManager.default.removeItem(at: url)
            }
        }
        return h
    }

    private func keys(_ h: Harness) throws -> [String?] {
        let id = h.nasId.rawValue
        return try h.store.read { db in
            try [IntegrityChecker.resultMissingKey, IntegrityChecker.resultMismatchKey, IntegrityChecker.resultAtKey,
                 IntegrityChecker.mismatchDismissedKey].map { key in
                try KeyValueRepository.int(db, key + id).map(String.init)
            }
        }
    }

    @Test func aResetClearsTheResultAndTheDismissal() async throws {
        let h = try await rottedLocal(rotted: 3)
        _ = try await h.coordinator.runIntegrityCheck(h.nasId)
        try await h.coordinator.dismissChecksumMismatch(h.nasId)
        #expect(try keys(h).contains { $0 != nil })
        try await h.coordinator.adoptExistingRoot(h.nasId, rootId: "")
        #expect(try keys(h).allSatisfy { $0 == nil })
        #expect(await h.coordinator.pendingOwnerDecisions().isEmpty)
    }

    @Test func mismatchedFilesAreNotAlsoCountedAsMissing() async throws {
        let h = try await rottedLocal(rotted: 3)
        _ = try await h.coordinator.runIntegrityCheck(h.nasId)
        let decisions = await h.coordinator.pendingOwnerDecisions()
        #expect(decisions == [.checksumMismatch(h.nasId, count: 3)])
        #expect(try h.jobs().filter { $0.state == .missingRemote }.count == 3, "all of them are still re-queued on confirm")
    }

    @Test func goneAndMismatchedFilesAreReportedSeparately() async throws {
        let h = try await rottedLocal(rotted: 2)
        _ = try await h.coordinator.runIntegrityCheck(h.nasId)
        let decisions = await h.coordinator.pendingOwnerDecisions()
        #expect(decisions.contains(.integrityMissing(h.nasId, count: 1)))
        #expect(decisions.contains(.checksumMismatch(h.nasId, count: 2)))
    }
}
