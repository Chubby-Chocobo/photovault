import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// Sidecar bytes differ per destination, and destinations upload in parallel: each one reads its own file.
@Suite struct SidecarStagingTests {
    @Test func theStagingPathOfASidecarCarriesTheDestinationAndTheGeneration() async throws {
        let h = try await Harness()
        let staging = StagingManager(env: h.env)
        let key = AssetKey.local("a")
        let drive = staging.fileURL(assetKey: key, type: .sidecarJson, generation: 2, destination: .googleDrive)
        let nas = staging.fileURL(assetKey: key, type: .sidecarJson, generation: 2, destination: h.nasId)
        let next = staging.fileURL(assetKey: key, type: .sidecarJson, generation: 3, destination: .googleDrive)
        #expect(Set([drive, nas, next]).count == 3)
        #expect(drive.deletingLastPathComponent() == nas.deletingLastPathComponent())
        // Resources keep the shared path: one export serves every destination.
        #expect(staging.fileURL(assetKey: key, type: .photo, generation: 2).lastPathComponent == "\(ResourceType.photo.rawValue).2")
    }

    @Test func destinationsReadDifferentFilesForTheSameSidecar() async throws {
        let h = try await Harness.organized()
        try await h.update {
            $0.viewByDeviceEnabled = false
            $0.viewByPlaceEnabled = false
            $0.viewFavoritesEnabled = false
            $0.placeNamesEnabled = false
        }
        let drive = WrappedDestination(h.drive)
        let nas = WrappedDestination(h.nas)
        await h.useWrapped(drive)
        await h.useWrapped(nas)
        h.overrides = [drive, nas]
        let paths = Box<[String: Set<String>]>([:])
        for (name, wrapper) in [("drive", drive), ("nas", nas)] {
            wrapper.beforeUpload = { request in
                guard request.job.resType.isSidecar else { return }
                paths.mutate { $0["\(request.job.resType.rawValue)", default: []].insert("\(name):\(request.content.file.path)") }
                #expect(FileManager.default.fileExists(atPath: request.content.file.path), "the file this destination reads exists")
            }
        }
        try h.addDrive(scope: .full)
        try h.addNAS(scope: .full)
        for index in 0..<3 { await h.add(h.snapshot("s\(index)", daysAgo: Double(index + 1)), recordChange: false) }
        try await h.baseline(.googleDrive, h.nasId)
        await h.settle()

        let seen = paths.get()
        #expect(!seen.isEmpty)
        for (_, entries) in seen {
            let files = entries.map { String($0.drop { $0 != ":" }) }
            #expect(Set(files).count == entries.count, "no two destinations or assets share a staging file: \(entries)")
        }
        #expect(try h.jobs().filter { $0.resType.isSidecar }.allSatisfy { $0.state == .done })
        #expect(h.stagingFiles().isEmpty)
    }
}
