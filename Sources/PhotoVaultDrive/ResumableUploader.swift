import Foundation
import PhotoVaultCore
import UniformTypeIdentifiers

/// Drive resumable upload protocol with a pre-generated ID (FR-44).
struct ResumableUploader: Sendable {
    static let chunkUnit = 256 * 1024
    static let defaultChunkSize = 8 * 1024 * 1024
    /// Consecutive transient failures tolerated per transfer before giving up.
    static let maxRecoveries = 3
    /// Consecutive acknowledgements that fail to advance the committed offset before giving up.
    static let maxStalls = 3

    enum Target: Sendable {
        case create(DriveFileWrite)
        case update(id: String)
    }

    private enum Probe {
        case done(DriveFile)
        case offset(Int64)
    }

    let http: DriveHTTP
    let chunkSize: Int
    let writeLimiter: DriveWriteLimiter?

    init(http: DriveHTTP, chunkSize: Int = ResumableUploader.defaultChunkSize, writeLimiter: DriveWriteLimiter? = nil) {
        self.http = http
        self.writeLimiter = writeLimiter
        self.chunkSize = max(Self.chunkUnit, chunkSize / Self.chunkUnit * Self.chunkUnit)
    }

    /// Starts a session, reports it through `onSession` BEFORE the first byte, then transfers.
    func upload(_ target: Target, file: URL, size: Int64, md5: String,
                onSession: @Sendable (SessionCheckpoint) async throws -> Void) async throws -> DriveFile {
        try await writeLimiter?.acquire(lane: .upload)
        let session = try await startSession(target, file: file, size: size)
        try await onSession(SessionCheckpoint(sessionRef: session.absoluteString, md5: md5, totalBytes: size))
        return try await transfer(session, file: file, size: size, from: 0)
    }

    /// Continues a persisted session; `.sessionExpired` when Drive no longer knows it.
    func resume(sessionRef: String, file: URL, size: Int64) async throws -> DriveFile {
        guard let session = URL(string: sessionRef), DriveURL.isTrustedSession(session) else { throw DestinationError.sessionExpired }
        switch try await probe(session, size: size) {
        case .done(let file): return file
        case .offset(let offset): return try await transfer(session, file: file, size: size, from: offset)
        }
    }

    // MARK: Protocol steps

    private func startSession(_ target: Target, file: URL, size: Int64) async throws -> URL {
        let method: String, url: URL, metadata: DriveFileWrite
        let query = [("uploadType", "resumable"), ("fields", DriveAPI.fileFields)]
        switch target {
        case .create(let write):
            (method, url, metadata) = ("POST", DriveURL.make(DriveURL.upload, "/files", query), write)
        case .update(let id):
            (method, url, metadata) = ("PATCH", DriveURL.make(DriveURL.upload, "/files/" + FormEncoding.escape(id), query), DriveFileWrite())
        }
        let headers = [
            "Content-Type": "application/json; charset=UTF-8",
            "X-Upload-Content-Type": Self.mimeType(for: file),
            "X-Upload-Content-Length": String(size),
        ]
        let (data, response) = try await http.send(url, method: method, headers: headers, body: .data(try JSONEncoder().encode(metadata)))
        if let error = DriveErrorMapper.error(data: data, response: response) {
            if case .alreadyExists = error { throw DestinationError.alreadyExists(remoteId: metadata.id ?? "") }
            throw error
        }
        guard let location = response.value(forHTTPHeaderField: "Location"), let session = URL(string: location),
              DriveURL.isTrustedSession(session) else {
            throw DestinationError.itemRejected(reason: "session uri missing")
        }
        return session
    }

    private func transfer(_ session: URL, file: URL, size: Int64, from start: Int64) async throws -> DriveFile {
        var offset = start
        var recoveries = 0
        var stalls = 0
        while true {
            if size > 0, offset >= size {
                // Everything is acknowledged but no final 200/201 arrived: ask for the final status.
                switch try await probe(session, size: size) {
                case .done(let finished): return finished
                case .offset(let acknowledged):
                    stalls += 1
                    guard stalls < Self.maxStalls else { throw DestinationError.transient(reason: "upload not finalised") }
                    offset = acknowledged
                    continue
                }
            }
            let end = min(offset + Int64(chunkSize), size)
            let range = size == 0 ? "bytes */0" : "bytes \(offset)-\(end - 1)/\(size)"
            let body: HTTPBody = size == 0 ? .none : .fileRange(file, offset: offset, length: Int(end - offset))
            var stalled = false
            do {
                let (data, response) = try await http.send(session, method: "PUT", headers: ["Content-Range": range], body: body)
                switch response.statusCode {
                case 200, 201: return try Self.decode(data)
                case 308:
                    let acknowledged = Self.nextOffset(response)
                    stalls = acknowledged > offset ? 0 : stalls + 1
                    stalled = stalls >= Self.maxStalls
                    offset = acknowledged
                    recoveries = 0
                case 404, 410: throw DestinationError.sessionExpired
                default: throw DriveErrorMapper.error(data: data, response: response) ?? DestinationError.server(status: response.statusCode)
                }
            } catch let error as DestinationError where Self.isRecoverable(error) {
                recoveries += 1
                guard recoveries <= Self.maxRecoveries else { throw error }
                switch try await probe(session, size: size) {
                case .done(let finished): return finished
                case .offset(let resumed): offset = resumed
                }
            }
            // Outside the recoverable-error handler: giving up must not trigger another recovery round.
            if stalled { throw DestinationError.transient(reason: "upload not progressing") }
        }
    }

    /// 400, 404 and 410 on a status query all mean Drive no longer accepts this session.
    private func probe(_ session: URL, size: Int64) async throws -> Probe {
        let (data, response) = try await http.send(session, method: "PUT", headers: ["Content-Range": "bytes */\(size)"])
        switch response.statusCode {
        case 200, 201: return .done(try Self.decode(data))
        case 308: return .offset(Self.nextOffset(response))
        case 400, 404, 410: throw DestinationError.sessionExpired
        default: throw DriveErrorMapper.error(data: data, response: response) ?? DestinationError.server(status: response.statusCode)
        }
    }

    private static func isRecoverable(_ error: DestinationError) -> Bool {
        switch error {
        case .server, .transient: true
        default: false
        }
    }

    /// `Range: bytes=0-N` means N+1 bytes are stored; no header means none.
    static func nextOffset(_ response: HTTPURLResponse) -> Int64 {
        guard let range = response.value(forHTTPHeaderField: "Range"), let dash = range.lastIndex(of: "-"),
              let last = Int64(range[range.index(after: dash)...]) else { return 0 }
        return last + 1
    }

    private static func decode(_ data: Data) throws -> DriveFile {
        guard let file = try? JSONDecoder().decode(DriveFile.self, from: data) else {
            throw DestinationError.itemRejected(reason: "upload response malformed")
        }
        return file
    }

    private static func mimeType(for file: URL) -> String {
        UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}
