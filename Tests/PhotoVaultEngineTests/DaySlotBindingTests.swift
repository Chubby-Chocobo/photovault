import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultEngine

typealias BoundResult = (inventory: RemoteInventory, conflicts: Int, guessed: Set<ArchiveDay>, byContents: Set<ArchiveDay>)

@Suite struct DaySlotBindingTests {
    let day = ArchiveDay(year: 2026, month: 11, day: 8)!
    let dest = DestinationID.local()

    func folder(_ name: String, id: String, logical: String = "camera/2026-11-08") -> RemoteFolderEntry {
        let (parsedDay, slot, place) = RemoteInventoryLoader.dayFolder(logical: logical, name: name)
        return RemoteFolderEntry(logicalPath: logical, remoteId: id, displayName: name, day: parsedDay, slot: slot, placeName: place)
    }

    func file(_ id: String, in parent: String) -> RemoteFileEntry {
        RemoteFileEntry(
            item: RemoteItem(remoteId: id, name: id, parentIds: [parent], kind: .file), parentLogical: "camera/2026-11-08", parentFolderId: parent)
    }

    func row(_ path: String, id: String) -> RemoteFolder {
        RemoteFolder(destinationId: dest, logicalPath: path, remoteId: id, displayName: "x", created: true)
    }

    func bind(
        _ folders: [RemoteFolderEntry], files: [RemoteFileEntry] = [], known: [DaySlot] = [], rows: [RemoteFolder] = [], drive: Bool = false,
        assetPaths: [String: String] = [:]
    ) -> BoundResult {
        var inventory = RemoteInventory()
        inventory.folders = folders
        inventory.files = files
        return DaySlotBinding.bind(inventory, known: known.isEmpty ? [:] : [day: known], rows: rows, isDrive: drive, slotPathOfAsset: assetPaths)
    }

    func path(_ result: BoundResult, _ id: String) -> String? {
        result.inventory.folders.first { $0.remoteId == id }?.logicalPath
    }

    @Test func anIntactDatabaseBindsByRemoteIdEvenWhenTheMainFolderIsNotFirstByName() {
        let folders = [folder("2026-11-08 Hà Nội", id: "/A"), folder("2026-11-08 Ninh Bình", id: "/B")]
        let result = bind(folders, rows: [row("camera/2026-11-08", id: "/B"), row("camera/2026-11-08@p0123456789ab", id: "/A")])
        #expect(path(result, "/B") == "camera/2026-11-08")
        #expect(path(result, "/A") == "camera/2026-11-08@p0123456789ab")
        #expect(result.conflicts == 0)
    }

    @Test func knownSlotsBindByDisplayNameWhenThisDestinationHasNoRows() {
        let known = [DaySlot(slot: nil, key: "VN|Hanoi", name: "Hà Nội"), DaySlot(slot: "p0123456789ab", key: "VN|Ninh Binh", name: "Ninh Bình")]
        let result = bind([folder("2026-11-08 Hà Nội", id: "/A"), folder("2026-11-08 Ninh Bình", id: "/B")], known: known)
        #expect(path(result, "/A") == "camera/2026-11-08")
        #expect(path(result, "/B") == "camera/2026-11-08@p0123456789ab")
    }

    @Test func aStaleMainRowDoesNotStopTheFolderNamedLikeTheKnownMain() {
        let known = [DaySlot(slot: nil, key: "K", name: "Hà Nội")]
        let result = bind([folder("2026-11-08 Hà Nội", id: "/new")], known: known, rows: [row("camera/2026-11-08", id: "/gone")])
        #expect(path(result, "/new") == "camera/2026-11-08")
    }

    @Test func aFolderKnownByNameKeepsItsPathWhateverSortsFirst() {
        // "Hanoi City" sorts before the main folder's name but is unknown: it must not take the main path.
        let known = [DaySlot(slot: nil, key: "K1", name: "Đà Lạt"), DaySlot(slot: "p0123456789ab", key: "K2", name: "Hà Nội")]
        let result = bind([folder("2026-11-08 Hanoi City", id: "/A"), folder("2026-11-08 Đà Lạt", id: "/B")], known: known)
        #expect(result.conflicts == 0)
        #expect(path(result, "/B") == "camera/2026-11-08")
        let other = path(result, "/A")
        #expect(other != "camera/2026-11-08" && other != "camera/2026-11-08@p0123456789ab")
        #expect(other?.hasPrefix("camera/2026-11-08@r") == true)
        #expect(result.guessed == [day])
    }

    @Test func anUnknownLocalFolderTakesTheKnownSlotHoldingItsAssets() {
        let known = [DaySlot(slot: nil, key: "K1", name: "Đà Lạt"), DaySlot(slot: "p0123456789ab", key: "K2", name: "Hà Nội")]
        let files = [file("f1", in: "/A"), file("f2", in: "/A")].map { entry -> RemoteFileEntry in
            var entry = entry
            entry.claimedKey = "l:" + entry.item.remoteId
            return entry
        }
        let result = bind(
            [folder("2026-11-08 Hanoi City", id: "/A"), folder("2026-11-08 Đà Lạt", id: "/B")], files: files, known: known,
            assetPaths: ["l:f1": "camera/2026-11-08@p0123456789ab", "l:f2": "camera/2026-11-08@p0123456789ab"])
        #expect(path(result, "/A") == "camera/2026-11-08@p0123456789ab")
        #expect(path(result, "/B") == "camera/2026-11-08")
        #expect(result.byContents == [day] && result.guessed.isEmpty)
    }

    @Test func unknownLocalFoldersTakeMainFirstThenStableRecoveredSlots() {
        let folders = [folder("2026-11-08 Ninh Bình", id: "/B"), folder("2026-11-08 Hà Nội", id: "/A")]
        let first = bind(folders)
        #expect(path(first, "/A") == "camera/2026-11-08")
        let other = path(first, "/B")
        #expect(other?.hasPrefix("camera/2026-11-08@r") == true)
        #expect(DynamicLayout.parseCameraDay(other ?? "") != nil)
        #expect(path(bind(folders.reversed()), "/B") == other, "stable and independent of input order")
    }

    @Test func aDrivePvLogicalAlreadyBoundInThisRunFallsBackToARecoveredSlot() {
        let result = bind([
            folder("2026-11-08 Hà Nội", id: "a"), folder("2026-11-08 Ninh Bình", id: "b"),
        ], drive: true)
        #expect(path(result, "a") == "camera/2026-11-08")
        #expect(path(result, "b")?.contains("@r") == true)
    }

    @Test func localFallbackBindingsAreMarkedAsGuessesAndKnownOnesAreNot() {
        let folders = [folder("2026-11-08 Hà Nội", id: "/A"), folder("2026-11-08 Ninh Bình", id: "/B")]
        #expect(bind(folders).guessed == [day])
        let known = [DaySlot(slot: nil, key: nil, name: "Hà Nội"), DaySlot(slot: "p0123456789ab", key: nil, name: "Ninh Bình")]
        #expect(bind(folders, known: known).guessed.isEmpty)
    }

    @Test func aDriveFolderKeepsItsPvLogicalWhenNothingElseKnowsIt() {
        let result = bind([folder("2026-11-08 Hà Nội", id: "a", logical: "camera/2026-11-08@p0123456789ab")], drive: true)
        #expect(path(result, "a") == "camera/2026-11-08@p0123456789ab")
    }

    @Test func twoListedFoldersForOneKnownPathReportAConflictAndTheSecondIsSkipped() {
        let known = [DaySlot(slot: nil, key: "K", name: "Hà Nội")]
        let files = [file("f1", in: "a"), file("f2", in: "b")]
        let result = bind([folder("2026-11-08 Hà Nội", id: "a"), folder("2026-11-08 Hà Nội", id: "b")], files: files, known: known, drive: true)
        #expect(result.conflicts == 1)
        #expect(result.inventory.folders.count == 1)
        #expect(result.inventory.files.first { $0.item.remoteId == "f1" }?.parentLogical == "camera/2026-11-08")
        #expect(result.inventory.files.contains { $0.item.remoteId == "f2" } == false, "left out of the recovery")
    }

    @Test func filesFollowTheirFolderAndTheResultIsDeterministic() {
        let folders = [folder("2026-11-08 Ninh Bình", id: "/B"), folder("2026-11-08 Hà Nội", id: "/A")]
        let files = [file("1", in: "/A"), file("2", in: "/B")]
        let one = bind(folders, files: files)
        let two = bind(folders.reversed(), files: files.reversed())
        let parentsOne: [String] = one.inventory.files.map { "\($0.item.remoteId)=\($0.parentLogical ?? "-")" }.sorted()
        let parentsTwo: [String] = two.inventory.files.map { "\($0.item.remoteId)=\($0.parentLogical ?? "-")" }.sorted()
        #expect(parentsOne == parentsTwo)
        #expect(one.inventory.files.first { $0.item.remoteId == "1" }?.parentLogical == "camera/2026-11-08")
    }

    @Test func foldersOutsideCameraDaysAreUntouched() {
        let screenshots = RemoteFolderEntry(logicalPath: "screenshot/2026-11-08", remoteId: "s", displayName: "2026-11-08")
        let result = bind([screenshots])
        #expect(path(result, "s") == "screenshot/2026-11-08")
    }
}
