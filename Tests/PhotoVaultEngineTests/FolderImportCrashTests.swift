import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// A crash at any point of an import leaves no duplicate asset or upload, and the job finishes after restart.
@Suite struct FolderImportCrashTests {
    @Test(arguments: [CrashPoint.afterImportInspectBeforeCommit, .afterImportGroupCommit, .afterExportBeforeCommit, .afterUploadBeforeCommit])
    func theJobResumesWithoutDuplicates(_ point: CrashPoint) async throws {
        let h = try await Harness { $0.importBatchGroups = 2 }
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        let folder = try ImportFolder()
        let date = h.clock.now.addingTimeInterval(-3 * 86_400)
        for index in 0..<5 { try folder.add("d/p\(index).jpg", metadata: ImportFolder.photo(at: date.addingTimeInterval(Double(index) * 100))) }
        try folder.add("d/p0.AAE")
        h.injector.arm(point)
        let id = try await h.coordinator.startFolderImport(source: folder.source(), displayName: "Trip", bookmark: nil)
        await h.settle(rounds: 1)
        #expect(h.injector.visited.contains(point), "the crash point was reached")
        try await h.restart()
        try await h.coordinator.start()
        for _ in 0..<6 {
            await h.run()
            h.clock.advance(by: 3 * 3600)
        }
        #expect(try h.source(id)?.status == .completed)
        #expect(try h.assets(of: id).count == 5)
        #expect(try h.jobs().count == 5 && (try h.jobs(.done).count == 5))
        #expect(await h.drive.files.count == 5)
        #expect(try h.importCounts(id) == [.imported: 5, .unsupported: 1])
        #expect(try h.importActivity().count == 1)
    }
}
