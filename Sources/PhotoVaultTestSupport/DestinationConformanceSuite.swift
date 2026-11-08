import Foundation
import PhotoVaultCore

/// Behavioural checks every `Destination` implementation must pass. Returns failure messages;
/// an empty array means the destination conforms. Run by the fake, Drive (stub transport) and
/// Local (temp directory) test suites.
public struct DestinationConformanceSuite: Sendable {
    public let destination: any Destination
    public let root: RemoteFolderRef
    public let scratch: URL

    public init(destination: any Destination, root: RemoteFolderRef, scratch: URL) {
        self.destination = destination
        self.root = root
        self.scratch = scratch
    }

    public func run() async -> [String] {
        var failures: [String] = []
        let checks: [(String, @Sendable () async throws -> String?)] = [
            ("folder idempotent", folderIsIdempotent),
            ("upload then probe", uploadThenProbe),
            ("same content same name", sameContentIsSuccess),
            ("conflicting original", conflictingOriginalGetsNewName),
            ("conflicting sidecar", conflictingSidecarIsRefused),
            ("replace content", replaceContent),
            ("move and rename", moveAndRename),
            ("list", listShowsItems),
        ]
        for (name, check) in checks {
            do {
                if let failure = try await check() { failures.append("\(name): \(failure)") }
            } catch {
                failures.append("\(name): unexpected error \(error)")
            }
        }
        return failures
    }

    private var reserves: Bool { destination.capabilities.reservesIds }

    private func reserve() async throws -> String? {
        reserves ? try await destination.reserveIds(count: 1, kind: .files).first : nil
    }

    private func folder(_ logical: String, _ name: String, parent: RemoteFolderRef? = nil) async throws -> RemoteFolderRef {
        try await destination.ensureFolder(FolderRequest(logicalPath: logical, name: name, parent: parent ?? root,
                                                         reservedId: try await reserve(),
                                                         appProperties: AppPropertyCodec.folderProperties(logicalPath: logical, view: nil)))
    }

    private func request(_ name: String, _ data: String, parent: RemoteFolderRef, kind: ResourceKind = .original,
                         prior: String? = nil) async throws -> UploadRequest {
        let content = try TestFiles.staged(Data(data.utf8), in: scratch)
        let type: ResourceType = switch kind {
        case .original: .photo
        case .edited: .fullSizePhoto
        case .sidecarJson: .sidecarJson
        case .sidecarXmp: .sidecarXmp
        }
        let identity = JobIdentity(destinationId: destination.id, assetKey: .local(UUID().uuidString), resType: type)
        return UploadRequest(job: identity, jobId: nil, kind: kind, reservedRemoteId: try await reserve(), parent: parent,
                             fileName: name, content: content, expectedPriorHash: prior)
    }

    private func upload(_ r: UploadRequest) async throws -> UploadResult {
        try await destination.upload(r, onSession: { _ in })
    }

    private func folderIsIdempotent() async throws -> String? {
        let a = try await folder("conf/a", "a")
        if reserves {
            let again = try await destination.ensureFolder(FolderRequest(
                logicalPath: "conf/a", name: "a", parent: root, reservedId: a.remoteId, appProperties: [:]))
            return again.remoteId == a.remoteId ? nil : "second ensureFolder with the same id returned another folder"
        }
        let b = try await folder("conf/a", "a")
        return a.remoteId == b.remoteId ? nil : "second ensureFolder created another folder"
    }

    private func uploadThenProbe() async throws -> String? {
        let parent = try await folder("conf/probe", "probe")
        let r = try await request("x.HEIC", "probe-bytes", parent: parent)
        let result = try await upload(r)
        let expected = r.content.hash(destination.capabilities.verifiedHash)
        guard result.verifiedHash == expected else { return "verified hash \(result.verifiedHash) != \(expected)" }
        guard let item = try await destination.probe(remoteId: result.remoteId) else { return "probe found nothing" }
        if let md5 = item.md5, destination.capabilities.verifiedHash == .md5, md5 != r.content.md5 { return "probe md5 differs" }
        if reserves, result.remoteId != r.reservedRemoteId { return "upload did not use the reserved id" }
        return nil
    }

    private func sameContentIsSuccess() async throws -> String? {
        guard !reserves else { return nil }
        let parent = try await folder("conf/same", "same")
        let first = try await upload(try await request("y.JPG", "same-bytes", parent: parent))
        let second = try await upload(try await request("y.JPG", "same-bytes", parent: parent))
        return first.remoteId == second.remoteId && second.finalName == "y.JPG" ? nil : "same content produced a second file"
    }

    private func conflictingOriginalGetsNewName() async throws -> String? {
        guard !reserves else { return nil }
        let parent = try await folder("conf/conflict", "conflict")
        _ = try await upload(try await request("z.JPG", "one", parent: parent))
        let second = try await upload(try await request("z.JPG", "two", parent: parent))
        return second.finalName != "z.JPG" && second.finalName.contains("(conflict-") ? nil : "conflict name was \(second.finalName)"
    }

    private func conflictingSidecarIsRefused() async throws -> String? {
        guard !reserves else { return nil }
        let parent = try await folder("conf/sidecar", "sidecar")
        _ = try await upload(try await request("s.json", "theirs", parent: parent, kind: .sidecarJson))
        do {
            _ = try await upload(try await request("s.json", "ours", parent: parent, kind: .sidecarJson))
            return "a foreign sidecar was overwritten"
        } catch DestinationError.foreignFile {
            return nil
        }
    }

    private func replaceContent() async throws -> String? {
        let parent = try await folder("conf/replace", "replace")
        let original = try await request("e (edited).HEIC", "v1", parent: parent, kind: .edited)
        let created = try await upload(original)
        let update = try await request("e (edited).HEIC", "v2", parent: parent, kind: .edited, prior: original.content.sha256)
        let replaced = try await destination.replaceContent(remoteId: created.remoteId, update)
        guard replaced.verifiedHash == update.content.hash(destination.capabilities.verifiedHash) else { return "content not replaced" }
        if !reserves {
            let wrong = try await request("e (edited).HEIC", "v3", parent: parent, kind: .edited, prior: "not-the-hash")
            do {
                _ = try await destination.replaceContent(remoteId: replaced.remoteId, wrong)
                return "replaced a file modified by someone else"
            } catch DestinationError.foreignModified {}
        }
        return nil
    }

    private func moveAndRename() async throws -> String? {
        let from = try await folder("conf/from", "from")
        let to = try await folder("conf/to", "to")
        let r = try await request("m.HEIC", "move-bytes", parent: from)
        let uploaded = try await upload(r)
        let moved = try await destination.move(remoteId: uploaded.remoteId, name: uploaded.finalName, from: from, to: to)
        if reserves, !moved.parentIds.contains(to.remoteId) { return "moved item not under target" }
        let renamed = try await destination.renameFolder(to, newName: "to renamed")
        if reserves {
            guard let probe = try await destination.probe(remoteId: moved.remoteId), probe.kind == .file else {
                return "file lost after folder rename"
            }
            return nil
        }
        // Local destinations identify files by path, so look the file up under the new name.
        var names: [String] = []
        for try await item in destination.list(under: renamed) { names.append(item.name) }
        return names.contains("m.HEIC") ? nil : "file lost after folder rename: \(names)"
    }

    private func listShowsItems() async throws -> String? {
        let parent = try await folder("conf/list", "list")
        let uploaded = try await upload(try await request("l.HEIC", "list-bytes", parent: parent))
        var names: [String] = []
        for try await item in destination.list(under: parent) { names.append(item.name) }
        return names.contains(uploaded.finalName) ? nil : "list did not include \(uploaded.finalName): \(names)"
    }
}
