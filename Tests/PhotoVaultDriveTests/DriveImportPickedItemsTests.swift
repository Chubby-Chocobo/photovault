import Foundation
import Testing
import PhotoVaultCore
@testable import PhotoVaultDrive

/// Many picked ids are read side by side, in a stable order, and one hiccup costs one retry, not the whole listing.
@Suite struct DriveImportPickedItemsTests {
    private func rig(files: Int) throws -> (ImportRig, [String]) {
        let rig = try ImportRig()
        var ids: [String] = []
        for index in 0..<files {
            let id = "f\(String(format: "%03d", index))"
            ids.append(id)
            rig.stub.add(.init(id: id, name: "IMG_\(String(format: "%03d", index)).jpg", content: Data("c\(index)".utf8)))
        }
        return (rig, ids)
    }

    @Test func manyPickedFilesAreReadInParallelUpToALimitAndListedInOrder() async throws {
        let (rig, ids) = try rig(files: 40)
        rig.stub.latency = .milliseconds(20)
        let entries = try await rig.source(Array(ids.reversed())).listFiles()
        #expect(entries.map(\.relativePath) == ids.indices.map { "IMG_\(String(format: "%03d", $0)).jpg" })
        #expect(rig.stub.peakInFlight > 1 && rig.stub.peakInFlight <= 8, "peak \(rig.stub.peakInFlight)")
    }

    @Test func oneServerErrorOnOnePickedFileRetriesThatFileOnly() async throws {
        let (rig, ids) = try rig(files: 12)
        rig.stub.failOnce("f005", with: .json(503, [:]))
        let entries = try await rig.source(ids).listFiles()
        #expect(entries.count == 12)
        #expect(rig.stub.metadataRequests(for: "f005") == 2)
        #expect(rig.stub.metadataRequests(for: "f004") == 1)
    }

    @Test func aFileThatKeepsFailingMakesTheListingBusy() async throws {
        let (rig, ids) = try rig(files: 3)
        rig.stub.fail("f001", with: .json(503, [:]))
        await #expect(throws: SourceError.busy) { _ = try await rig.source(ids).listFiles() }
    }
}
