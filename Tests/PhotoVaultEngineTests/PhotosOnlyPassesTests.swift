import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// Passes that walk the Photos library must leave assets from other sources alone.
@Suite struct PhotosOnlyPassesTests {
    private func imported(_ h: Harness) async throws -> (AssetKey, FakeContentSource) {
        let folder = FakeContentSource()
        let key = try await h.seedImported("holiday", source: folder, status: .importing, destinations: [])
        return (key, folder)
    }

    @Test func reconciliationDoesNotMarkImportedAssetsGone() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("p1", daysAgo: 5), recordChange: false)
        try await h.baseline(.googleDrive)
        await h.run()
        let (key, _) = try await imported(h)
        await h.add(h.snapshot("expiry-marker", daysAgo: 400), recordChange: true)
        await h.fakePhotos.expireHistory()
        h.clock.advance(by: 60)
        await h.run()
        #expect(try h.asset(key)?.deletedAt == nil, "an imported asset is not a Photos asset that disappeared")
        await h.fakePhotos.delete(localId: "p1")
        await h.fakePhotos.expireHistory()
        await h.run()
        #expect(try h.asset(.local("p1"))?.deletedAt != nil, "Photos assets still follow the library")
        #expect(try h.asset(key)?.deletedAt == nil)
    }

    @Test func cloudIdBackfillNeverAsksPhotosAboutImports() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("p1", daysAgo: 5, cloud: "cloud-1"), recordChange: false)
        try await h.baseline(.googleDrive)
        let (key, _) = try await imported(h)
        let recorded = try await CloudIdBackfill(env: h.env).runAll(force: true)
        let asked = h.photos.cloudMappingRequests
        #expect(asked.allSatisfy { !$0.contains("/") }, "\(asked)")
        #expect(!asked.isEmpty || recorded == 0)
        #expect(try h.asset(key)?.cloudId == nil)
    }

    @Test func editGateNeverAsksPhotosAboutImports() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        let (key, _) = try await imported(h)
        try h.write { db in
            var asset = try #require(try AssetRepository.fetch(db, key: key))
            asset.hasAdjustments = true
            asset.editCheckPending = true
            try AssetRepository.upsert(db, asset, timeZone: utc)
        }
        let staging = StagingManager(env: h.env)
        _ = try await EditGate(env: h.env, resourceGuard: ResourceGuard(env: h.env, staging: staging)).runPass()
        #expect(h.photos.adjustmentHashRequests.isEmpty)
        #expect(try h.asset(key)?.editCheckPending == false)
    }

    @Test func classifyWorkerSkipsImportedAssets() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        let (key, _) = try await imported(h)
        try h.write { db in
            var asset = try #require(try AssetRepository.fetch(db, key: key))
            asset.categoryProvisional = true
            asset.categoryReason = .pendingHeaderRead
            try AssetRepository.upsert(db, asset, timeZone: utc)
        }
        let staging = StagingManager(env: h.env)
        _ = try await ClassifyWorker(env: h.env, resourceGuard: ResourceGuard(env: h.env, staging: staging), staging: staging).runPass()
        #expect(await h.fakePhotos.headerReads.isEmpty)
        #expect(try h.asset(key)?.categoryProvisional == true)
    }
}
