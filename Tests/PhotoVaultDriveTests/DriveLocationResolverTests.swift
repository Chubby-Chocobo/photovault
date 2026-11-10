import Foundation
import Testing
@testable import PhotoVaultDrive

private struct Boom: Error {}

/// A Drive tree as the resolver sees it: id → node, with "root" an alias of the My Drive root.
private final class Tree: @unchecked Sendable {
    private let lock = NSLock()
    private var nodes: [String: DriveLocationNode] = [:]
    private var calls: [String] = []
    var failing: Set<String> = []

    init() { add("R", "My Drive") }
    func add(_ id: String, _ name: String, parent: String? = nil, driveId: String? = nil, folder: Bool = true) {
        nodes[id] = DriveLocationNode(id: id, name: name, mimeType: folder ? DriveMime.folder : "image/jpeg",
                                      parents: parent.map { [$0] }, driveId: driveId)
    }
    func lookup(_ id: String) async throws -> DriveLocationNode {
        lock.withLock { calls.append(id) }
        if failing.contains(id) { throw Boom() }
        guard let node = nodes[id == "root" ? "R" : id] else { throw Boom() }
        return node
    }
    func lookups(of id: String) -> Int { lock.withLock { calls.filter { $0 == id }.count } }
    var total: Int { lock.withLock { calls.count } }
    func resolve(picked: [String], maxDepth: Int = 20, maxPicks: Int = 5, maxLookups: Int = 100) async -> DriveImportLocations? {
        var resolver = DriveLocationResolver(lookup: { [self] in try await lookup($0) }, maxDepth: maxDepth, maxPicks: maxPicks, maxLookups: maxLookups)
        return await resolver.resolve(picked: picked)
    }
}

@Suite struct DriveLocationResolverTests {
    @Test func folderInMyDriveShowsItsFullChain() async {
        let tree = Tree()
        tree.add("T", "Trips", parent: "R")
        tree.add("Y", "2024", parent: "T")
        let result = await tree.resolve(picked: ["Y"])
        #expect(result?.paths == ["My Drive/Trips/2024"])
        #expect(result?.webURL == "https://drive.google.com/drive/folders/Y")
    }

    @Test func pickedFileShowsItsParentFolder() async {
        let tree = Tree()
        tree.add("T", "Trips", parent: "R")
        tree.add("f", "a.jpg", parent: "T", folder: false)
        let result = await tree.resolve(picked: ["f"])
        #expect(result?.paths == ["My Drive/Trips"])
        #expect(result?.webURL == "https://drive.google.com/drive/folders/T")
    }

    @Test func folderSharedWithMeStartsAtSharedWithMe() async {
        let tree = Tree()
        tree.add("S", "Holiday")
        tree.add("C", "Day 1", parent: "S")
        #expect(await tree.resolve(picked: ["S"])?.paths == ["Shared with me/Holiday"])
        #expect(await tree.resolve(picked: ["C"])?.paths == ["Shared with me/Holiday/Day 1"])
    }

    @Test func fileSharedDirectlyHasOnlySharedWithMe() async {
        let tree = Tree()
        tree.add("f", "a.jpg", folder: false)
        let result = await tree.resolve(picked: ["f"])
        #expect(result?.paths == ["Shared with me"])
        #expect(result?.webURL == nil)
    }

    @Test func sharedDriveStartsAtTheDriveName() async {
        let tree = Tree()
        tree.add("D", "Family", driveId: "D")
        tree.add("X", "Scans", parent: "D", driveId: "D")
        #expect(await tree.resolve(picked: ["X"])?.paths == ["Family/Scans"])
    }

    @Test func aSharedDriveWhoseNameCannotBeReadIsCalledSharedDriveNeverByItsId() async {
        let tree = Tree()
        tree.add("D-secret-id", "Family", driveId: "D-secret-id")
        tree.add("X", "Scans", parent: "D-secret-id", driveId: "D-secret-id")
        tree.add("Y", "2024", parent: "X", driveId: "D-secret-id")
        tree.failing = ["D-secret-id"]
        let path = await tree.resolve(picked: ["Y"])?.paths.first
        #expect(path == "Shared drive/Scans/2024")
        #expect(path?.contains("secret") == false)
    }

    @Test func severalPicksKeepOrderAndShareLookups() async {
        let tree = Tree()
        tree.add("T", "Trips", parent: "R")
        tree.add("a", "a.jpg", parent: "T", folder: false)
        tree.add("b", "b.jpg", parent: "T", folder: false)
        tree.add("O", "Other", parent: "R")
        let result = await tree.resolve(picked: ["a", "O", "b"])
        #expect(result?.paths == ["My Drive/Trips", "My Drive/Other", "My Drive/Trips"])
        #expect(tree.lookups(of: "T") == 1)
        #expect(result?.webURL == "https://drive.google.com/drive/folders/T")
    }

    @Test func onlyTheFirstPicksAreResolved() async {
        let tree = Tree()
        for n in 1...8 { tree.add("f\(n)", "p\(n).jpg", parent: "R", folder: false) }
        let result = await tree.resolve(picked: (1...8).map { "f\($0)" }, maxPicks: 5)
        #expect(result?.paths.count == 5)
    }

    @Test func aDeepChainIsCutAtTheDepthCap() async {
        let tree = Tree()
        var parent = "R"
        for level in 1...30 {
            tree.add("L\(level)", "n\(level)", parent: parent)
            parent = "L\(level)"
        }
        let path = await tree.resolve(picked: ["L30"], maxDepth: 20)?.paths.first
        let parts = path?.split(separator: "/").map(String.init) ?? []
        #expect(parts.first == "…")
        #expect(parts.last == "n30")
        #expect(parts.count == 21)
        #expect(!parts.contains("My Drive"))
    }

    @Test func aParentCycleEndsInsteadOfLooping() async {
        let tree = Tree()
        tree.add("A", "A", parent: "B")
        tree.add("B", "B", parent: "A")
        let path = await tree.resolve(picked: ["A"])?.paths.first
        #expect(path?.hasPrefix("…/") == true)
        #expect(tree.total < 10)
    }

    @Test func anyErrorGivesNoLocation() async {
        let tree = Tree()
        tree.add("T", "Trips", parent: "R")
        tree.add("Y", "2024", parent: "T")
        tree.failing = ["T"]
        #expect(await tree.resolve(picked: ["Y"]) == nil)
        tree.failing = ["root"]
        #expect(await tree.resolve(picked: ["Y"]) == nil)
        #expect(await tree.resolve(picked: ["missing"]) == nil)
        #expect(await tree.resolve(picked: []) == nil)
    }

    @Test func theRequestBudgetStopsAWalk() async {
        let tree = Tree()
        var parent = "R"
        for level in 1...15 { tree.add("L\(level)", "n\(level)", parent: parent); parent = "L\(level)" }
        #expect(await tree.resolve(picked: ["L15"], maxLookups: 5) == nil)
    }

    @Test func aCancelledWalkGivesNoLocation() async {
        let tree = Tree()
        tree.add("T", "Trips", parent: "R")
        let task = Task { () -> DriveImportLocations? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await tree.resolve(picked: ["T"])
        }
        #expect(await task.value == nil)
    }
}
