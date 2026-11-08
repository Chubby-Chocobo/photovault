import Foundation
import PhotoVaultCore
import PhotoVaultTestSupport
@testable import PhotoVaultLocal

struct LocalFixture {
    let root: URL
    let scratch: URL
    let destination: LocalFolderDestination
    let rootRef = RemoteFolderRef.root(remoteId: "")

    init(disk: (any DiskSpaceProvider)? = nil) throws {
        // Resolve /var -> /private/var once so assertions on paths are simple.
        let base = try TestFiles.temporaryDirectory("pv-local").resolvingSymlinksInPath()
        root = base.appendingPathComponent("root", isDirectory: true)
        scratch = base.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        destination = LocalFolderDestination(id: .local(), root: PlainURLRoot(root), disk: disk)
    }

    var tmpURL: URL { root.appendingPathComponent(".photovault/tmp") }

    func folder(_ name: String, in parent: RemoteFolderRef? = nil) async throws -> RemoteFolderRef {
        try await destination.ensureFolder(FolderRequest(logicalPath: name, name: name, parent: parent ?? rootRef,
                                                         reservedId: nil, appProperties: [:]))
    }

    func request(_ name: String, _ text: String, in parent: RemoteFolderRef, kind: ResourceKind = .original,
                 prior: String? = nil) throws -> UploadRequest {
        let content = try TestFiles.staged(Data(text.utf8), in: scratch)
        let identity = JobIdentity(destinationId: destination.id, assetKey: .local(UUID().uuidString),
                                   resType: kind == .original ? .photo : .sidecarJson)
        return UploadRequest(job: identity, jobId: nil, kind: kind, reservedRemoteId: nil, parent: parent,
                             fileName: name, content: content, expectedPriorHash: prior)
    }

    func upload(_ request: UploadRequest) async throws -> UploadResult {
        try await destination.upload(request, onSession: { _ in })
    }

    func text(_ relative: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func names(_ relative: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(relative).path).sorted()
    }

    func write(_ relative: String, _ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(relative))
    }
}

func expectError(_ expected: DestinationError, _ body: () async throws -> Void) async -> Bool {
    do {
        try await body()
        return false
    } catch let error as DestinationError {
        return error == expected
    } catch {
        return false
    }
}
