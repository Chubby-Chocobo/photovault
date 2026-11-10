import Foundation
import PhotoVaultCore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultLocal

@Suite struct LocalQueueSplitTests {
    /// Blocks the copy thread until `release()` and tells when the copy got that far.
    private final class Gate: @unchecked Sendable {
        private let entered = DispatchSemaphore(value: 0)
        private let released = DispatchSemaphore(value: 0)
        func block() { entered.signal(); released.wait() }
        func waitUntilBlocked() -> Bool { entered.wait(timeout: .now() + 60) == .success }
        func release() { released.signal() }
    }

    @Test func probesAndChecksDoNotWaitBehindACopy() async throws {
        let base = try TestFiles.temporaryDirectory("pv-queue").resolvingSymlinksInPath()
        let root = base.appendingPathComponent("root", isDirectory: true)
        let scratch = base.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let gate = Gate()
        let destination = LocalFolderDestination(id: .local(), root: PlainURLRoot(root), renameMemo: ExclusiveRenameMemo(),
                                                 afterStaging: { gate.block() })
        let folder = try await destination.ensureFolder(FolderRequest(logicalPath: "d", name: "d", parent: .root(remoteId: ""),
                                                                      reservedId: nil, appProperties: [:]))
        let content = try TestFiles.staged(Data("big".utf8), in: scratch)
        let identity = JobIdentity(destinationId: destination.id, assetKey: .local("a"), resType: .photo)
        let request = UploadRequest(job: identity, jobId: nil, kind: .original, reservedRemoteId: nil, parent: folder,
                                    fileName: "a.bin", content: content, expectedPriorHash: nil)
        let upload = Task { try await destination.upload(request, onSession: { _ in }) }
        let blocked = await Task.detached { gate.waitUntilBlocked() }.value
        #expect(blocked)

        #expect(try await destination.probe(remoteId: "d/missing.bin") == nil)
        #expect(await destination.checkAvailability() == .active)
        #expect(try await destination.readMarker() == nil)
        #expect(try await destination.readSmallFile(remoteId: "d/missing.json") == nil)

        gate.release()
        _ = try await upload.value
        #expect(try await destination.probe(remoteId: "d/a.bin") != nil)
    }
}
