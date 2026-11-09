import Foundation
import Testing
import PhotoVaultCore
import PhotoVaultTestSupport
@testable import PhotoVaultDrive

struct Harness {
    let server: FakeDriveServer
    let destination: GoogleDriveDestination
    let root: RemoteFolderRef
    let scratch: URL
    let clock: FixedClock
    var interceptor: InterceptingTransport?

    static func make(chunkSize: Int = 256 * 1024, sessionPrefix: String = "up", cap: DailyUploadCap = DailyUploadCap(),
                     dailyCapState: DailyCapState? = nil, onDailyCapChange: (@Sendable (DailyCapState) -> Void)? = nil,
                     writeLimiter: DriveWriteLimiter? = DriveWriteLimiter.standard(),
                     transport: ((FakeDriveServer) -> any HTTPTransport)? = nil, log: any LogSink = NullLogSink()) async throws -> Harness {
        let server = FakeDriveServer(sessionPrefix: sessionPrefix)
        let clock = FixedClock()
        let made = transport?(server) ?? server
        let destination = GoogleDriveDestination(transport: made, auth: StaticAuth(), cap: cap, dailyCapState: dailyCapState,
                                                 onDailyCapChange: onDailyCapChange, writeLimiter: writeLimiter,
                                                 chunkSize: chunkSize, clock: clock, log: log)
        let id = try await destination.reserveIds(count: 1, kind: .files)[0]
        let item = try await destination.createRoot(reservedId: id, name: "Camera Uploads",
                                                    appProperties: AppPropertyCodec.rootProperties(archiveTimezone: TimeZone(identifier: "Asia/Ho_Chi_Minh")!))
        await destination.setRootId(item.remoteId)
        return Harness(server: server, destination: destination, root: .root(remoteId: item.remoteId), scratch: try tempDir(),
                       clock: clock, interceptor: made as? InterceptingTransport)
    }

    func folder(_ name: String, parent: RemoteFolderRef? = nil) async throws -> RemoteFolderRef {
        let id = try await destination.reserveIds(count: 1, kind: .files)[0]
        return try await destination.ensureFolder(FolderRequest(logicalPath: name, name: name, parent: parent ?? root, reservedId: id,
                                                                appProperties: AppPropertyCodec.folderProperties(logicalPath: name, view: nil)))
    }

    func request(_ data: Data, name: String = "a.HEIC", parent: RemoteFolderRef, id: String? = nil) async throws -> UploadRequest {
        let content = try TestFiles.staged(data, in: scratch)
        let reserved: String
        if let id { reserved = id } else { reserved = try await destination.reserveIds(count: 1, kind: .files)[0] }
        return UploadRequest(job: JobIdentity(destinationId: .googleDrive, assetKey: .local("A"), resType: .photo), jobId: 1, kind: .original,
                             reservedRemoteId: reserved, parent: parent, fileName: name, content: content,
                             appProperties: ["pvResType": "photo"], description: "Camera: X")
    }
}

func payload(_ size: Int) -> Data { Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }

final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}

@Suite struct ResumableFlowTests {
    @Test func sessionIsReportedBeforeAnyByteAndChunksAreAligned() async throws {
        let h = try await Harness.make(chunkSize: 256 * 1024)
        let parent = try await h.folder("p")
        let req = try await h.request(payload(600 * 1024), parent: parent)
        let events = Events()
        let result = try await h.destination.upload(req) { checkpoint in
            let puts = await h.server.requests.filter { $0.method == "PUT" }.count
            events.add("session puts=\(puts) md5=\(checkpoint.md5 == req.content.md5) bytes=\(checkpoint.totalBytes)")
        }
        #expect(events.all == ["session puts=0 md5=true bytes=\(600 * 1024)"])
        #expect(result.remoteId == req.reservedRemoteId && result.verifiedHash == req.content.md5)
        let puts = await h.server.requests.filter { $0.method == "PUT" }
        #expect(puts.map { $0.headers["Content-Range"] } == [
            "bytes 0-262143/614400", "bytes 262144-524287/614400", "bytes 524288-614399/614400",
        ])
        #expect(puts.allSatisfy { $0.headers["Authorization"] == "Bearer static-token" })
        let start = await h.server.requests.first { $0.method == "POST" && $0.url.path == "/upload/drive/v3/files" }!
        #expect(start.query["uploadType"] == "resumable" && start.json["id"] as? String == req.reservedRemoteId)
        #expect(start.headers["X-Upload-Content-Length"] == "614400")
        let stored = await h.server.item(result.remoteId)
        #expect(stored?.content == payload(600 * 1024) && stored?.desc == "Camera: X")
        #expect(stored?.props["pvSchema"] == "1" && stored?.props["pvResType"] == "photo")
    }

    @Test func transientChunkFailureProbesAndResumesFromServerOffset() async throws {
        let h = try await Harness.make(chunkSize: 256 * 1024)
        let parent = try await h.folder("p")
        // The first chunk reaches the server but its response is lost: the probe reports it stored.
        let req = try await h.request(payload(700 * 1024), parent: parent)
        await h.server.setPutFailures([.init(status: 503, storeBytes: true)])
        let result = try await h.destination.upload(req, onSession: { _ in })
        let ranges = await h.server.requests.filter { $0.method == "PUT" }.map { $0.headers["Content-Range"]! }
        #expect(ranges[0] == "bytes 0-262143/716800")
        #expect(ranges[1] == "bytes */716800")
        #expect(ranges[2] == "bytes 262144-524287/716800")
        #expect(result.size == 700 * 1024)
    }

    @Test func resumeUploadContinuesFromProbe() async throws {
        let h = try await Harness.make(chunkSize: 256 * 1024)
        let parent = try await h.folder("p")
        let req = try await h.request(payload(700 * 1024), parent: parent)
        let saved = Events()
        await h.server.setPutFailures([.init(status: 503, storeBytes: true), .init(status: 503, storeBytes: false),
                                       .init(status: 503, storeBytes: false), .init(status: 503, storeBytes: false)])
        await #expect(throws: DestinationError.server(status: 503)) {
            try await h.destination.upload(req) { saved.add($0.sessionRef) }
        }
        let ref = saved.all[0]
        let checkpoint = SessionCheckpoint(sessionRef: ref, md5: req.content.md5, totalBytes: req.content.size)
        let result = try await h.destination.resumeUpload(req, session: checkpoint, onSession: { _ in })
        #expect(result.verifiedHash == req.content.md5)
        let ranges = await h.server.requests.filter { $0.method == "PUT" }.map { $0.headers["Content-Range"]! }
        let probeIndex = ranges.lastIndex(of: "bytes */716800")!
        #expect(Array(ranges[(probeIndex + 1)...]) == ["bytes 262144-524287/716800", "bytes 524288-716799/716800"])
    }

    @Test func lostSessionIsSessionExpired() async throws {
        let h = try await Harness.make()
        let parent = try await h.folder("p")
        let req = try await h.request(payload(1000), parent: parent)
        let saved = Events()
        await h.server.setPutFailures([.init(status: 503, storeBytes: false), .init(status: 503, storeBytes: false),
                                       .init(status: 503, storeBytes: false), .init(status: 503, storeBytes: false)])
        _ = try? await h.destination.upload(req) { saved.add($0.sessionRef) }
        await h.server.dropSessions()
        let checkpoint = SessionCheckpoint(sessionRef: saved.all[0], md5: req.content.md5, totalBytes: 1000)
        await #expect(throws: DestinationError.sessionExpired) { try await h.destination.resumeUpload(req, session: checkpoint, onSession: { _ in }) }
    }

    @Test func untrustedSessionHostNeverReceivesTheToken() async throws {
        let h = try await Harness.make()
        let parent = try await h.folder("p")
        let req = try await h.request(payload(10), parent: parent)
        let evil = SessionCheckpoint(sessionRef: "https://evil.example/upload?upload_id=1", md5: req.content.md5, totalBytes: 10)
        let before = await h.server.requests.count
        await #expect(throws: DestinationError.sessionExpired) { try await h.destination.resumeUpload(req, session: evil, onSession: { _ in }) }
        #expect(await h.server.requests.count == before)
    }

    @Test func checksumMismatchIsReported() async throws {
        let h = try await Harness.make()
        let parent = try await h.folder("p")
        await h.server.setCorruptMD5(true)
        let req = try await h.request(payload(1000), parent: parent)
        await #expect(throws: DestinationError.self) { try await h.destination.upload(req, onSession: { _ in }) }
        do { _ = try await h.destination.upload(try await h.request(payload(1000), parent: parent), onSession: { _ in }) } catch let DestinationError.checksumMismatch(expected, actual) {
            #expect(expected != actual)
            return
        }
        Issue.record("expected checksumMismatch")
    }

    @Test func duplicateReservedIdIsAlreadyExists() async throws {
        let h = try await Harness.make()
        let parent = try await h.folder("p")
        let first = try await h.request(payload(10), parent: parent)
        _ = try await h.destination.upload(first, onSession: { _ in })
        let again = try await h.request(payload(10), parent: parent, id: first.reservedRemoteId)
        await #expect(throws: DestinationError.alreadyExists(remoteId: first.reservedRemoteId!)) {
            try await h.destination.upload(again, onSession: { _ in })
        }
    }

    @Test func tooLongAppPropertyIsRejectedBeforeAnyRequest() async throws {
        let h = try await Harness.make()
        let parent = try await h.folder("p")
        var req = try await h.request(payload(10), parent: parent)
        req.appProperties["pvAssetId"] = String(repeating: "x", count: 130)
        let before = await h.server.requests.count
        await #expect(throws: DestinationError.itemRejected(reason: "appProperties pair too long")) { try await h.destination.upload(req, onSession: { _ in }) }
        #expect(await h.server.requests.count == before)
    }

    @Test func replaceContentVerifiesMD5() async throws {
        let h = try await Harness.make()
        let parent = try await h.folder("p")
        let created = try await h.destination.upload(try await h.request(payload(500), parent: parent), onSession: { _ in })
        let update = try await h.request(payload(900), parent: parent)
        let replaced = try await h.destination.replaceContent(remoteId: created.remoteId, update)
        #expect(replaced.verifiedHash == update.content.md5)
        #expect(await h.server.item(created.remoteId)?.content == payload(900))
        let patch = await h.server.requests.last { $0.method == "PATCH" && $0.url.path.hasPrefix("/upload") }
        #expect(patch?.url.path == "/upload/drive/v3/files/\(created.remoteId)")
    }

    @Test func dailyCapBlocksUploads() async throws {
        let h = try await Harness.make(cap: DailyUploadCap(limit: 1500))
        let parent = try await h.folder("p")
        _ = try await h.destination.upload(try await h.request(payload(1000), parent: parent), onSession: { _ in })
        #expect(await h.destination.dailyUsage() == 1000)
        await #expect(throws: DestinationError.dailyCapReached) { try await h.destination.upload(try await h.request(payload(1000), parent: parent), onSession: { _ in }) }
        h.clock.advance(24 * 3600 + 1)
        #expect(await h.destination.dailyUsage() == 0)
        _ = try await h.destination.upload(try await h.request(payload(1000), parent: parent), onSession: { _ in })
    }
}

@Suite struct FolderAndRootTests {
    @Test func rootTrashedOrMissingPausesAndIsNeverRecreated() async throws {
        let h = try await Harness.make()
        #expect(await h.destination.checkAvailability() == .active)
        await h.server.trash(h.root.remoteId)
        #expect(await h.destination.checkAvailability() == .paused(.rootTrashed))
        await #expect(throws: DestinationError.rootTrashed) { try await h.folder("x") }
        func creates() async -> Int { await h.server.requests.filter { $0.method == "POST" && $0.url.path == "/drive/v3/files" }.count }
        await h.server.remove(h.root.remoteId)
        let before = await creates()
        #expect(await h.destination.checkAvailability() == .paused(.rootMissing))
        #expect(await creates() == before)
    }

    @Test func untrashRestoresRoot() async throws {
        let h = try await Harness.make()
        await h.server.trash(h.root.remoteId)
        _ = try await h.destination.untrash(remoteId: h.root.remoteId)
        #expect(await h.destination.checkAvailability() == .active)
    }

    @Test func findRootsReturnsOnlyPvRoot() async throws {
        let h = try await Harness.make()
        _ = try await h.folder("not-a-root")
        let roots = try await h.destination.findRoots()
        #expect(roots.map(\.remoteId) == [h.root.remoteId])
        #expect(roots[0].appProperties["pvArchiveTZ"] == "Asia/Ho_Chi_Minh")
        let list = await h.server.requests.last { $0.method == "GET" && $0.url.path == "/drive/v3/files" }!
        #expect(list.query["q"]!.contains("key='pvRoot' and value='1'"))
    }

    @Test func existingFolderWithSameIdIsVerifiedNotAssumed() async throws {
        let h = try await Harness.make()
        let a = try await h.folder("a")
        let again = try await h.destination.ensureFolder(FolderRequest(logicalPath: "a", name: "a", parent: h.root, reservedId: a.remoteId, appProperties: [:]))
        #expect(again.remoteId == a.remoteId)
        let renamedElsewhere = FolderRequest(logicalPath: "a", name: "different", parent: h.root, reservedId: a.remoteId, appProperties: [:])
        await #expect(throws: DestinationError.alreadyExists(remoteId: a.remoteId)) { try await h.destination.ensureFolder(renamedElsewhere) }
        let b = try await h.folder("b")
        let wrongParent = FolderRequest(logicalPath: "a", name: "a", parent: b, reservedId: a.remoteId, appProperties: [:])
        await #expect(throws: DestinationError.alreadyExists(remoteId: a.remoteId)) { try await h.destination.ensureFolder(wrongParent) }
    }

    @Test func trashedAndMissingParents() async throws {
        let h = try await Harness.make()
        let parent = try await h.folder("p")
        await h.server.trash(parent.remoteId)
        await #expect(throws: DestinationError.folderTrashed(logicalPath: "p")) { try await h.folder("child", parent: parent) }
        await #expect(throws: DestinationError.folderTrashed(logicalPath: "p")) {
            try await h.destination.upload(try await h.request(payload(10), parent: parent), onSession: { _ in })
        }
        await h.server.remove(parent.remoteId)
        await #expect(throws: DestinationError.folderMissing(logicalPath: "p")) { try await h.folder("child", parent: parent) }
        await #expect(throws: DestinationError.folderMissing(logicalPath: "p")) {
            try await h.destination.upload(try await h.request(payload(10), parent: parent), onSession: { _ in })
        }
    }

    @Test func probeReturnsNilWhenMissing() async throws {
        let h = try await Harness.make()
        #expect(try await h.destination.probe(remoteId: "nope") == nil)
    }

    @Test func listPagesThroughAllItems() async throws {
        let h = try await Harness.make()
        let parent = try await h.folder("p")
        for i in 0..<5 { _ = try await h.destination.upload(try await h.request(payload(10 + i), name: "f\(i)", parent: parent), onSession: { _ in }) }
        var names: [String] = []
        for try await item in h.destination.list(under: parent) { names.append(item.name) }
        #expect(Set(names) == Set((0..<5).map { "f\($0)" }))
    }

    @Test func listingIncludesTrashedItems() async throws {
        let h = try await Harness.make()
        for try await _ in h.destination.list(under: nil) {}
        let list = try #require(await h.server.requests.last { $0.method == "GET" && $0.url.path == "/drive/v3/files" })
        #expect(!(list.query["q"] ?? "").contains("trashed=false"))
    }

    @Test func updateMetadataAndQuota() async throws {
        let h = try await Harness.make()
        try await h.destination.updateMetadata(remoteId: h.root.remoteId, description: "hello", appProperties: ["pvArchiveTZ": "UTC"])
        #expect(await h.server.item(h.root.remoteId)?.desc == "hello")
        #expect(try await h.destination.quota() == Quota(totalBytes: 1000, usedBytes: 250, availableBytes: 750))
    }
}

@Suite struct ShortcutTests {
    @Test func createMoveTrashShortcut() async throws {
        let h = try await Harness.make()
        let a = try await h.folder("a"), b = try await h.folder("b")
        let file = try await h.destination.upload(try await h.request(payload(10), parent: a), onSession: { _ in })
        let sid = try await h.destination.reserveIds(count: 1, kind: .shortcuts)[0]
        let request = ShortcutRequest(reservedId: sid, targetId: file.remoteId, parent: a, name: "s", appProperties: ["pvView": "byPlace"])
        let item = try await h.destination.createShortcut(request)
        #expect(item.kind == .shortcut && item.shortcutTargetId == file.remoteId)
        #expect(try await h.destination.createShortcut(request).remoteId == sid)
        let moved = try await h.destination.moveShortcut(remoteId: sid, from: a, to: b)
        #expect(moved.parentIds == [b.remoteId])
        try await h.destination.trashShortcut(remoteId: sid)
        #expect(await h.server.item(sid)?.trashed == true)
        await #expect(throws: DestinationError.itemRejected(reason: "not a shortcut")) { try await h.destination.trashShortcut(remoteId: file.remoteId) }
        #expect(await h.server.item(file.remoteId)?.trashed == false)
    }

    @Test func shortcutWithDifferentTargetIsNotAssumed() async throws {
        let h = try await Harness.make()
        let a = try await h.folder("a")
        let sid = try await h.destination.reserveIds(count: 1, kind: .shortcuts)[0]
        _ = try await h.destination.createShortcut(ShortcutRequest(reservedId: sid, targetId: "T1", parent: a, name: "s", appProperties: [:]))
        await #expect(throws: DestinationError.alreadyExists(remoteId: sid)) {
            try await h.destination.createShortcut(ShortcutRequest(reservedId: sid, targetId: "T2", parent: a, name: "s", appProperties: [:]))
        }
    }

    @Test func forbiddenMapsToViewsNotPermitted() async throws {
        let h = try await Harness.make()
        let a = try await h.folder("a")
        await h.server.setShortcutStatus(403)
        let sid = try await h.destination.reserveIds(count: 1, kind: .shortcuts)[0]
        await #expect(throws: DestinationError.viewsNotPermitted) {
            try await h.destination.createShortcut(ShortcutRequest(reservedId: sid, targetId: "T", parent: a, name: "s", appProperties: [:]))
        }
    }
}

@Suite struct ConformanceTests {
    @Test func driveDestinationPassesTheSharedSuite() async throws {
        let h = try await Harness.make()
        let failures = await DestinationConformanceSuite(destination: h.destination, root: h.root, scratch: h.scratch).run()
        #expect(failures.isEmpty, "\(failures)")
        #expect(h.destination.capabilities.reservesIds && h.destination.capabilities.verifiedHash == .md5)
    }
}
