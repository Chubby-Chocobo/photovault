import Foundation
import Testing
import PhotoVaultCore
@testable import PhotoVaultDrive

private func killedUpload(_ h: Harness, _ req: UploadRequest) async -> String? {
    let saved = Events()
    await h.server.setPutFailures(Array(repeating: .init(status: 503, storeBytes: false), count: 4))
    _ = try? await h.destination.upload(req) { saved.add($0.sessionRef) }
    return saved.all.first
}

@Suite struct ChunkErrorMappingTests {
    @Test func notFoundDuringChunkIsSessionExpiredNotFolderMissing() async throws {
        let h = try await Harness.make()
        let parent = try await h.folder("p")
        let req = try await h.request(payload(1000), parent: parent)
        await h.server.setPutFailures([.init(status: 404, storeBytes: false)])
        await #expect(throws: DestinationError.sessionExpired) { try await h.destination.upload(req, onSession: { _ in }) }
        let rootReq = try await h.request(payload(1000), parent: h.root)
        await h.server.setPutFailures([.init(status: 410, storeBytes: false)])
        await #expect(throws: DestinationError.sessionExpired) { try await h.destination.upload(rootReq, onSession: { _ in }) }
    }

    @Test func notFoundOnSessionStartStillMeansParentMissing() async throws {
        let h = try await Harness.make()
        let parent = try await h.folder("p")
        let req = try await h.request(payload(10), parent: parent)
        await h.server.remove(parent.remoteId)
        await #expect(throws: DestinationError.folderMissing(logicalPath: "p")) { try await h.destination.upload(req, onSession: { _ in }) }
        let rootReq = try await h.request(payload(10), parent: h.root)
        await h.server.remove(h.root.remoteId)
        await #expect(throws: DestinationError.rootMissing) { try await h.destination.upload(rootReq, onSession: { _ in }) }
    }

    @Test func resumeStatusQueryInvalidSessionStatusesAreSessionExpired() async throws {
        for status in [400, 404, 410] {
            let h = try await Harness.make(transport: { server in
                InterceptingTransport(base: server) { request in
                    request.httpMethod == "PUT" && request.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes */") == true
                        ? .json(status, ["error": ["errors": [["reason": "badRequest"]]]]) : nil
                }
            })
            let parent = try await h.folder("p")
            let req = try await h.request(payload(1000), parent: parent)
            let ref = try #require(await killedUpload(h, req))
            h.interceptor?.arm()
            let checkpoint = SessionCheckpoint(sessionRef: ref, md5: req.content.md5, totalBytes: 1000)
            await #expect(throws: DestinationError.sessionExpired, "status \(status)") {
                try await h.destination.resumeUpload(req, session: checkpoint, onSession: { _ in })
            }
        }
    }
}

@Suite struct ResumeValidationTests {
    @Test func checkpointForOtherContentIsNotResumed() async throws {
        let h = try await Harness.make()
        let parent = try await h.folder("p")
        let req = try await h.request(payload(1000), parent: parent)
        let ref = try #require(await killedUpload(h, req))
        let before = await h.server.requests.count
        let otherMD5 = SessionCheckpoint(sessionRef: ref, md5: "0123456789abcdef0123456789abcdef", totalBytes: 1000)
        await #expect(throws: DestinationError.sessionExpired) { try await h.destination.resumeUpload(req, session: otherMD5, onSession: { _ in }) }
        let otherSize = SessionCheckpoint(sessionRef: ref, md5: req.content.md5, totalBytes: 2000)
        await #expect(throws: DestinationError.sessionExpired) { try await h.destination.resumeUpload(req, session: otherSize, onSession: { _ in }) }
        #expect(await h.server.requests.count == before)
        #expect(await h.destination.dailyUsage() == 0)
    }
}

@Suite struct ForwardProgressTests {
    private func uploader(size: Int, _ handler: @escaping @Sendable (RecordedRequest) -> StubResponse) throws -> (ResumableUploader, URL, StubTransport) {
        let transport = StubTransport { r in
            r.method != "PUT"
                ? StubResponse(status: 200, headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=s1"])
                : handler(r)
        }
        let file = try tempDir().appendingPathComponent("f.bin")
        try Data(count: size).write(to: file)
        let http = DriveHTTP(transport: transport, auth: StaticAuth())
        return (ResumableUploader(http: http, chunkSize: 256 * 1024), file, transport)
    }

    private static let done = StubResponse.json(200, ["id": "x", "md5Checksum": "m"])

    @Test func offsetThatNeverAdvancesFailsTransiently() async throws {
        let size = 1_000_000
        let (up, file, transport) = try uploader(size: size) { _ in StubResponse(status: 308, headers: ["Range": "bytes=0-262143"]) }
        await #expect(throws: DestinationError.transient(reason: "upload not progressing")) {
            try await up.upload(.update(id: "x"), file: file, size: Int64(size), md5: "m", onSession: { _ in })
        }
        // One chunk of progress, then three acknowledgements without advancing.
        #expect(transport.requests.filter { $0.method == "PUT" }.count == 4)
    }

    @Test func fullyAcknowledgedUploadIsFinalisedWithStatusQuery() async throws {
        let size = 100
        let (up, file, transport) = try uploader(size: size) { r in
            r.headers["Content-Range"] == "bytes */100" ? Self.done : StubResponse(status: 308, headers: ["Range": "bytes=0-99"])
        }
        let result = try await up.upload(.update(id: "x"), file: file, size: Int64(size), md5: "m", onSession: { _ in })
        #expect(result.id == "x")
        #expect(transport.requests.filter { $0.method == "PUT" }.map { $0.headers["Content-Range"] } == ["bytes 0-99/100", "bytes */100"])
    }

    @Test func neverFinalisingServerEndsTransiently() async throws {
        let (up, file, _) = try uploader(size: 100) { _ in StubResponse(status: 308, headers: ["Range": "bytes=0-99"]) }
        await #expect(throws: DestinationError.transient(reason: "upload not finalised")) {
            try await up.upload(.update(id: "x"), file: file, size: 100, md5: "m", onSession: { _ in })
        }
    }
}

private final class ChangeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [DailyCapState] = []
    func add(_ s: DailyCapState) { lock.withLock { states.append(s) } }
    var all: [DailyCapState] { lock.withLock { states } }
}

@Suite struct DailyCapReservationTests {
    @Test func restoredStateCountsAfterRestart() async throws {
        let log = ChangeLog()
        let first = try await Harness.make(cap: DailyUploadCap(limit: 1500), onDailyCapChange: { log.add($0) })
        let parent = try await first.folder("p")
        _ = try await first.destination.upload(try await first.request(payload(1000), parent: parent), onSession: { _ in })
        let persisted = try #require(log.all.last)
        #expect(persisted.entries.map(\.bytes) == [1000])
        let data = try JSONEncoder().encode(persisted)

        let second = try await Harness.make(cap: DailyUploadCap(limit: 1500), dailyCapState: try JSONDecoder().decode(DailyCapState.self, from: data))
        #expect(await second.destination.dailyUsage() == 1000)
        let parent2 = try await second.folder("p")
        await #expect(throws: DestinationError.dailyCapReached) {
            try await second.destination.upload(try await second.request(payload(1000), parent: parent2), onSession: { _ in })
        }
    }

    @Test func concurrentUploadsNearTheCapAdmitOnlyOne() async throws {
        let h = try await Harness.make(cap: DailyUploadCap(limit: 1500))
        let parent = try await h.folder("p")
        let a = try await h.request(payload(1000), name: "a.HEIC", parent: parent)
        let b = try await h.request(payload(1000), name: "b.HEIC", parent: parent)
        async let first: Result<UploadResult, any Error> = { do { return .success(try await h.destination.upload(a, onSession: { _ in })) } catch { return .failure(error) } }()
        async let second: Result<UploadResult, any Error> = { do { return .success(try await h.destination.upload(b, onSession: { _ in })) } catch { return .failure(error) } }()
        let results = await [first, second]
        let admitted = results.filter { if case .success = $0 { true } else { false } }.count
        #expect(admitted == 1)
        let rejected = results.compactMap { r -> DestinationError? in if case .failure(let e) = r { e as? DestinationError } else { nil } }
        #expect(rejected == [.dailyCapReached])
        #expect(await h.destination.dailyUsage() == 1000)
    }

    @Test func failedUploadReleasesItsReservation() async throws {
        let log = ChangeLog()
        let h = try await Harness.make(cap: DailyUploadCap(limit: 1500), onDailyCapChange: { log.add($0) })
        let parent = try await h.folder("p")
        let req = try await h.request(payload(1000), parent: parent)
        await h.server.setPutFailures([.init(status: 404, storeBytes: false)])
        await #expect(throws: DestinationError.sessionExpired) { try await h.destination.upload(req, onSession: { _ in }) }
        #expect(await h.destination.dailyUsage() == 0)
        #expect(log.all.map { $0.entries.count } == [1, 0])
        _ = try await h.destination.upload(try await h.request(payload(1000), parent: parent), onSession: { _ in })
        #expect(await h.destination.dailyUsage() == 1000)
    }

    @Test func uploadedButMismatchedBytesStayCounted() async throws {
        let h = try await Harness.make(cap: DailyUploadCap(limit: 5000))
        let parent = try await h.folder("p")
        await h.server.setCorruptMD5(true)
        _ = try? await h.destination.upload(try await h.request(payload(1000), parent: parent), onSession: { _ in })
        #expect(await h.destination.dailyUsage() == 1000)
    }
}

private final class Tick: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_800_000_000)
    private var slept: [TimeInterval] = []
    var now: Date { lock.withLock { time } }
    func sleep(_ seconds: TimeInterval) { lock.withLock { slept.append(seconds); time += seconds } }
    var sleeps: [TimeInterval] { lock.withLock { slept } }
}

@Suite struct WriteLimiterTests {
    @Test func metadataWritesWaitWhenTheBucketIsLow() async throws {
        let tick = Tick()
        let limiter = DriveWriteLimiter(capacity: 4, refillPerSecond: 1, now: { tick.now }, sleep: { tick.sleep($0) })
        try await limiter.acquire(lane: .metadata)
        try await limiter.acquire(lane: .metadata)
        #expect(tick.sleeps.isEmpty)
        try await limiter.acquire(lane: .upload)  // the reserve is for uploads
        #expect(tick.sleeps.isEmpty)
        try await limiter.acquire(lane: .metadata)
        #expect(!tick.sleeps.isEmpty)
    }

    @Test func destinationWritesGoThroughTheLimiter() async throws {
        let tick = Tick()
        let limiter = DriveWriteLimiter(capacity: 4, refillPerSecond: 1, now: { tick.now }, sleep: { tick.sleep($0) })
        let h = try await Harness.make(writeLimiter: limiter)  // createRoot already used one token
        for name in ["a", "b", "c", "d"] { _ = try await h.folder(name) }
        #expect(!tick.sleeps.isEmpty)
        let before = tick.sleeps.count
        _ = try await h.destination.upload(try await h.request(payload(10), parent: h.root), onSession: { _ in })
        #expect(tick.sleeps.count >= before)
        let reads = try await h.destination.quota()
        #expect(reads != nil)
    }
}
