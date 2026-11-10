import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import Testing
@testable import PhotoVaultEngine

@Suite struct SplitDayLayoutResolverTests {
    let day = ArchiveDay(year: 2026, month: 11, day: 8)!
    let slot = "p0123456789ab"
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let layout = DynamicLayout()
    let drive = DestinationID.googleDrive

    /// A placed camera asset on `day`, a `day_stat` in `state`, and optionally a slot and its row.
    private func makeStore(
        state: PlaceState = .pending, statName: String? = nil, assetSlot: String? = nil, rowName: String?? = nil
    ) throws -> (Store, AssetRecord) {
        let store = try Store.inMemory()
        let asset = try store.write { db -> AssetRecord in
            let record = AssetRecord(
                assetKey: .local("A"), localId: "A", creationDate: now, mediaType: .image, category: .camera,
                firstSeenAt: now, lastSeenAt: now)
            try AssetRepository.upsert(db, record, timeZone: TimeZone(identifier: "UTC")!)
            _ = try AssetPlacementRepository.allocatePlacement(
                db, assetKey: record.assetKey, baseStem: "IMG_0001", category: .camera, day: .day(day), now: now)
            try AssetPlacementRepository.recountDay(db, day: day)
            try DayStatRepository.setPlace(db, day: day, state: state, key: statName == nil ? nil : "VN|X", name: statName)
            if let assetSlot { try AssetPlacementRepository.setPlaceSlot(db, key: record.assetKey, slot: assetSlot) }
            if let rowName { try DayPlaceRepository.save(db, DayPlace(day: day, slot: slot, placeKey: "VN|Y", placeName: rowName)) }
            return try AssetRepository.fetch(db, key: record.assetKey) ?? record
        }
        return (store, asset)
    }

    private func chain(_ store: Store, _ asset: AssetRecord) throws -> [FolderLevel] {
        try store.read { db in try LayoutResolver.chain(db, asset: asset, layout: layout) }
    }

    @Test(arguments: [(PlaceState.named, "Đà Lạt"), (.unnamed, nil), (.pending, nil)] as [(PlaceState, String?)])
    func nullSlotResolvesAsBefore(state: PlaceState, name: String?) throws {
        let (store, asset) = try makeStore(state: state, statName: name)
        let expected = layout.folderChain(for: asset.placement!, placeName: state == .named ? name : nil)
        #expect(try chain(store, asset) == expected)
    }

    @Test func waitingDayKeepsItsStoredName() throws {
        let (named, asset) = try makeStore(state: .waitingGeocode, statName: "Đà Lạt")
        #expect(try chain(named, asset).last?.displayName == "2026-11-08 Đà Lạt")
        let (fresh, other) = try makeStore(state: .waitingGeocode, statName: nil)
        #expect(try chain(fresh, other).last?.displayName == "2026-11-08")
    }

    @Test func slotResolvesToTheSiblingFolderWithTheRowName() throws {
        let (store, asset) = try makeStore(state: .named, statName: "Hà Nội", assetSlot: slot, rowName: "Ninh Bình")
        let last = try #require(chain(store, asset).last)
        #expect(last == FolderLevel(logicalPath: "camera/2026-11-08@\(slot)", displayName: "2026-11-08 Ninh Bình"))
    }

    @Test func slotWithoutARowUsesTheBareDate() throws {
        let (store, asset) = try makeStore(state: .named, statName: "Hà Nội", assetSlot: slot)
        let last = try #require(chain(store, asset).last)
        #expect(last == FolderLevel(logicalPath: "camera/2026-11-08@\(slot)", displayName: "2026-11-08"))
    }

    @Test func uploadCompletionQueuesAMoveIntoTheSlotFolder() throws {
        let (store, asset) = try makeStore(state: .named, statName: "Hà Nội", assetSlot: slot, rowName: "Ninh Bình")
        let identity = JobIdentity(destinationId: drive, assetKey: asset.assetKey, resType: .photo)
        try store.write { db in
            try JobRepository.upsert(db, desired: .init(identity: identity, origin: .incremental, targetGen: 1), now: now)
            _ = try JobRepository.apply(db, .startUpload(generation: 1), to: identity, now: now)
            try UploadCompletion.commit(
                db, identity: identity, remoteId: "f1", finalName: "IMG_0001.HEIC", uploadedParent: "camera/2026-11-08",
                verifiedHash: "h", layout: layout, now: now)
        }
        let moves = try store.read { try MoveJobRepository.fetch($0, destinationId: drive, state: .pending) }
        #expect(moves.count == 1)
        #expect(moves.first?.operation == .moveFile)
        #expect(moves.first?.fromValue == "camera/2026-11-08")
        #expect(moves.first?.toValue == "camera/2026-11-08@\(slot)")
    }

    @Test func legacyLayoutIgnoresSlotPaths() throws {
        let (store, asset) = try makeStore(state: .named, statName: "Hà Nội", assetSlot: slot, rowName: "Ninh Bình")
        let path = "camera/2026-11-08@\(slot)"
        try store.write { db in
            try RemoteFolderRepository.save(db, RemoteFolder(destinationId: drive, logicalPath: path, remoteId: "d1", displayName: "x", created: true))
            let identity = JobIdentity(destinationId: drive, assetKey: asset.assetKey, resType: .photo)
            try JobRepository.upsert(db, desired: .init(identity: identity, origin: .incremental, targetGen: 1), now: now)
            _ = try JobRepository.apply(db, .startUpload(generation: 1), to: identity, now: now)
            _ = try JobRepository.apply(db, .uploadSucceeded(remoteId: "f", finalName: "n", parent: path, verifiedHash: "h"), to: identity, now: now)
        }
        #expect(try store.read { try LegacyLayout.isPresent($0) } == false)
        #expect(LegacyRootProbe.isLegacyLogicalPath(path) == false)
    }
}
