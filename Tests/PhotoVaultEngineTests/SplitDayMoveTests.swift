import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// Moves that split a day survive a process death at every step, stay within the per-pass cap,
/// and late photos land in their folder without a move.
@Suite struct SplitDayMoveTests {
    enum Target: String, CaseIterable, Sendable { case drive, nas, local }

    private let day = organizationDay
    private var hanoiFolder: String { "\(day) Hà Nội" }
    private var daLatFolder: String { "\(day) Đà Lạt" }

    /// Names are off while the photos upload into the bare day folder; turning them on queues the split.
    private func prepare(
        _ target: Target, hanoiCount: Int = 10, daLatCount: Int = 3, tuning: ((inout EngineTuning) -> Void)? = nil
    ) async throws -> (Harness, URL?) {
        let h = try await Harness.organized {
            $0.maxConcurrentUploadsPerDestination = 1
            tuning?(&$0)
        }
        try await h.update {
            $0.viewByDeviceEnabled = false
            $0.viewByPlaceEnabled = false
            $0.viewFavoritesEnabled = false
            $0.placeNamesEnabled = false
        }
        var root: URL?
        switch target {
        case .drive: try h.addDrive(scope: .full)
        case .nas: try h.addNAS(scope: .full)
        case .local:
            root = try await h.useRealLocal().root
            try h.addNAS(scope: .full)
        }
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        await h.geocoder.seed(hanoi, en: hanoiEnglish, local: hanoiVietnamese)
        for index in 0..<hanoiCount { await h.add(h.snapshot("h\(index)", daysAgo: 3, location: hanoi), recordChange: false) }
        for index in 0..<daLatCount { await h.add(h.snapshot("d\(index)", daysAgo: 3, location: daLat), recordChange: false) }
        try await h.baseline(target == .drive ? .googleDrive : h.nasId)
        await h.settle()
        try await h.update { $0.placeNamesEnabled = true }
        return (h, root)
    }

    private func recover(_ h: Harness) async throws {
        try await h.restart()
        try await h.coordinator.start()
        await h.settle(rounds: 8)
    }

    /// Every file once, in its group's folder; sidecars beside their originals.
    private func expectSplit(
        _ h: Harness, _ target: Target, root: URL?, hanoiCount: Int = 10, daLatCount: Int = 3, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        var locations: [String] = []
        switch target {
        case .drive: for file in await h.drive.files { locations.append(await h.drive.path(of: file.id)) }
        case .nas: for file in await h.nas.files { locations.append(await h.nas.path(of: file.id)) }
        case .local: locations = treeListing(try #require(root)).keys.filter { !$0.hasPrefix(".photovault") }.sorted()
        }
        let photos = locations.filter { !$0.hasSuffix(".json") && !$0.hasSuffix(".xmp") }
        let sidecars = locations.filter { $0.hasSuffix(".json") || $0.hasSuffix(".xmp") }
        #expect(photos.filter { $0.hasPrefix("Camera Uploads/\(hanoiFolder)/") }.count == hanoiCount, "\(locations)", sourceLocation: sourceLocation)
        #expect(photos.filter { $0.hasPrefix("Camera Uploads/\(daLatFolder)/") }.count == daLatCount, sourceLocation: sourceLocation)
        #expect(sidecars.filter { $0.hasPrefix("Camera Uploads/\(daLatFolder)/") }.count == 2 * daLatCount, sourceLocation: sourceLocation)
        #expect(sidecars.filter { $0.hasPrefix("Camera Uploads/\(hanoiFolder)/") }.count == 2 * hanoiCount, sourceLocation: sourceLocation)
        #expect(Set(locations).count == locations.count, sourceLocation: sourceLocation)
        #expect(!locations.contains { $0.hasSuffix(".part") }, sourceLocation: sourceLocation)
        for dest in [DestinationID.googleDrive, h.nasId] {
            for state in [MoveJobState.pending, .inProgress, .failed] {
                #expect(try h.moveJobs(state, destination: dest).isEmpty, "\(state) at \(dest)", sourceLocation: sourceLocation)
            }
        }
        let slot = try #require(try h.asset(.local("d0"))?.placeSlot, sourceLocation: sourceLocation)
        let slotPath = "camera/\(day)@\(slot)"
        for job in try h.jobs() where job.assetKey.rawValue.contains("d") && job.state == .done {
            #expect(job.remoteLogicalParent == slotPath, sourceLocation: sourceLocation)
            if target == .local { #expect(job.remoteId?.contains(daLatFolder) == true, sourceLocation: sourceLocation) }
        }
    }

    @Test(arguments: Target.allCases, [CrashPoint.afterMoveStarted, .afterMoveBeforeCommit])
    func crashDuringASplitMoveLeavesEveryFileOnceInItsFolder(_ target: Target, _ point: CrashPoint) async throws {
        let (h, root) = try await prepare(target)
        h.injector.arm(point)
        await h.run()
        #expect(h.injector.visited.contains(point), "the crash point was reached")
        try await recover(h)
        try await expectSplit(h, target, root: root)
    }

    @Test(arguments: [CrashPoint.afterFolderIdPersisted, .afterFolderCreated])
    func crashWhileTheFirstMoveCreatesTheNewFolderCreatesItOnce(_ point: CrashPoint) async throws {
        let (h, _) = try await prepare(.drive)
        h.injector.arm(point)
        await h.run()
        #expect(h.injector.visited.contains(point))
        try await recover(h)
        let twins = Dictionary(grouping: await h.drive.folders.filter { $0.id != "root" }, by: { "\($0.parentId)/\($0.name)" })
        #expect(twins.values.allSatisfy { $0.count == 1 })
        #expect(await h.drive.folders.filter { $0.name == daLatFolder }.count == 1)
        try await expectSplit(h, .drive, root: nil)
    }

    @Test func aPassRunsAtMostTheCapAndTheRestFollows() async throws {
        let (h, _) = try await prepare(.drive, hanoiCount: 5, daLatCount: 5) { $0.maxMovesPerPass = 2 }
        let uploader = UploadRunner(env: h.env, staging: StagingManager(env: h.env))
        let worker = MoveWorker(env: h.env, uploader: uploader)
        try h.write { db in
            for index in 0..<5 {
                let key = AssetKey.local("d\(index)")
                try AssetPlacementRepository.setPlaceSlot(db, key: key, slot: "p0123456789ab")
                let asset = try #require(try AssetRepository.fetch(db, key: key))
                let target = LayoutResolver.parentLogical(try LayoutResolver.chain(db, asset: asset, layout: DynamicLayout()))
                for job in try JobRepository.fetchAll(db, assetKey: key) {
                    try MoveJobPlanner.enqueueMove(
                        db, identity: JobIdentity(destinationId: job.destinationId, assetKey: key, resType: job.resType),
                        from: job.remoteLogicalParent ?? "", to: target, now: h.clock.now)
                }
            }
        }
        let pending = try h.moveJobs(.pending, destination: .googleDrive).filter { $0.operation == .moveFile }.count
        #expect(pending >= 5)
        var passes: [Int] = []
        while passes.count < 10 {
            let done = try await worker.runPass()
            if done == 0 { break }
            passes.append(done)
        }
        #expect(passes.allSatisfy { $0 <= 2 }, "\(passes)")
        #expect(passes.reduce(0, +) >= pending)
        #expect(passes.count >= 3)
        #expect(try h.moveJobs(.pending, destination: .googleDrive).isEmpty)
        #expect(try h.moveJobs(.failed, destination: .googleDrive).isEmpty)
    }

    @Test func aCrashInTheMiddleOfAnUpgradeBacklogUnderTheCapLosesAndDuplicatesNothing() async throws {
        let (h, _) = try await prepare(.drive, hanoiCount: 12, daLatCount: 8) { $0.maxMovesPerPass = 5 }
        let count = Box(0)
        h.injector.onReach { point in
            guard point == .afterMoveBeforeCommit else { return }
            count.mutate { $0 += 1 }
            if count.get() == 13 { throw SimulatedCrash(point: point.rawValue) }
        }
        await h.run()
        #expect(count.get() >= 13, "the crash fell in the middle of the backlog")
        h.injector.onReach(nil)
        try await recover(h)
        try await expectSplit(h, .drive, root: nil, hanoiCount: 12, daLatCount: 8)
    }

    // MARK: Late arrivals

    private func splitHarness() async throws -> Harness {
        let h = try await Harness.organized()
        try await h.update {
            $0.viewByDeviceEnabled = false
            $0.viewByPlaceEnabled = false
            $0.viewFavoritesEnabled = false
        }
        try h.addDrive(scope: .full)
        await h.geocoder.seed(daLat, en: daLatEnglish, local: daLatVietnamese)
        await h.geocoder.seed(hanoi, en: hanoiEnglish, local: hanoiVietnamese)
        let base = h.clock.now.addingTimeInterval(-3 * 86_400)
        for index in 0..<10 { await h.add(timed(h, "h\(index)", base, minutes: Double(index), hanoi), recordChange: false) }
        for index in 0..<3 { await h.add(timed(h, "d\(index)", base, minutes: 100 + Double(index), daLat), recordChange: false) }
        try await h.baseline(.googleDrive)
        await h.settle()
        return h
    }

    private func timed(_ h: Harness, _ id: String, _ base: Date, minutes: Double, _ location: GeoPoint?) -> AssetSnapshot {
        var snapshot = h.snapshot(id, daysAgo: 3, location: location)
        snapshot.creationDate = base.addingTimeInterval(minutes * 60)
        return snapshot
    }

    private func moveFileCount(_ h: Harness) throws -> Int {
        try h.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM move_job WHERE op = 'moveFile'") ?? 0 }
    }

    @Test func aLatePhotoWithoutGpsUploadsStraightIntoTheNearestFoldersSlot() async throws {
        let h = try await splitHarness()
        let moves = try moveFileCount(h)
        #expect(moves > 0)
        await h.add(timed(h, "late", organizationBase(h), minutes: 107, nil))
        await h.settle()
        let slot = try #require(try h.asset(.local("d0"))?.placeSlot)
        #expect(try h.asset(.local("late"))?.placeSlot == slot)
        #expect(try moveFileCount(h) == moves)
        let path = try #require(await h.backupPaths(h.drive).first { $0.contains("late") })
        #expect(path.hasPrefix("Camera Uploads/\(daLatFolder)/"), "\(path)")
    }

    @Test func aLateGpsPhotoFromTheMainProvinceGoesStraightToTheMainFolder() async throws {
        let h = try await splitHarness()
        let moves = try moveFileCount(h)
        await h.add(timed(h, "late", organizationBase(h), minutes: 103, hanoi))
        await h.settle()
        #expect(try h.asset(.local("late"))?.placeSlot == nil)
        #expect(try moveFileCount(h) == moves)
        let path = try #require(await h.backupPaths(h.drive).first { $0.contains("late") })
        #expect(path.hasPrefix("Camera Uploads/\(hanoiFolder)/"), "\(path)")
    }

    private func organizationBase(_ h: Harness) -> Date { h.clock.now.addingTimeInterval(-3 * 86_400) }

    @Test func aMoveWhoseSlotFlippedBackBeforeItRanIsDiscardedWithoutADestinationCall() async throws {
        let (h, _) = try await prepare(.drive, hanoiCount: 2, daLatCount: 1)
        try await h.update { $0.placeNamesEnabled = false }
        let key = AssetKey.local("d0")
        let callsBefore = await h.drive.operationLog.filter { $0 == .move }.count
        try h.write { db in
            try AssetPlacementRepository.setPlaceSlot(db, key: key, slot: "p0123456789ab")
            let asset = try #require(try AssetRepository.fetch(db, key: key))
            let target = LayoutResolver.parentLogical(try LayoutResolver.chain(db, asset: asset, layout: DynamicLayout()))
            let job = try #require(try JobRepository.fetchAll(db, assetKey: key).first { $0.destinationId == .googleDrive && $0.remoteId != nil })
            try MoveJobPlanner.enqueueMove(
                db, identity: JobIdentity(destinationId: .googleDrive, assetKey: key, resType: job.resType),
                from: job.remoteLogicalParent ?? "", to: target, now: h.clock.now)
            try AssetPlacementRepository.setPlaceSlot(db, key: key, slot: nil)
        }
        #expect(try h.moveJobs(.pending, destination: .googleDrive).contains { $0.operation == .moveFile })
        let worker = MoveWorker(env: h.env, uploader: UploadRunner(env: h.env, staging: StagingManager(env: h.env)))
        _ = try await worker.runPass()
        #expect(try h.moveJobs(.pending, destination: .googleDrive).filter { $0.operation == .moveFile }.isEmpty)
        #expect(await h.drive.operationLog.filter { $0 == .move }.count == callsBefore)
    }
}
