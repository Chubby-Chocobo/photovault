import Foundation
import PhotoVaultCore
import PhotoVaultDrive

/// Dropbox HTTP API calls. Errors are `SourceError`; they never carry paths, names or tokens.
public struct DropboxClient: Sendable {
    /// Longest `Retry-After` honoured by waiting; a longer one reports the source as unavailable.
    static let maxRetryWait: TimeInterval = 30
    static let pageSize = 2000

    enum Attempt<T> {
        case done(T)
        case failed(status: Int, body: Data, retryAfter: TimeInterval?)
    }

    private let tokens: any DropboxAccessTokenProviding
    private let transport: any HTTPTransport
    private let streamer: any DropboxByteStreaming
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(tokens: any DropboxAccessTokenProviding, transport: any HTTPTransport,
                streamer: any DropboxByteStreaming = URLSessionByteStreamer(),
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.tokens = tokens
        self.transport = transport
        self.streamer = streamer
        self.sleep = sleep
    }

    // MARK: Account

    public func currentAccountEmail() async throws -> String {
        try await Self.decodeEmail(rpc("users/get_current_account", body: nil))
    }

    /// Used by sign-in, before a token provider exists.
    static func currentAccountEmail(accessToken: String, transport: any HTTPTransport) async throws -> String {
        let attempt = try await send(rpcRequest("users/get_current_account", token: accessToken), body: .none, via: transport)
        switch attempt {
        case .done(let data): return try decodeEmail(data)
        case .failed(let status, let body, _): throw error(status: status, body: body)
        }
    }

    private static func decodeEmail(_ data: Data) throws -> String {
        struct Account: Decodable { var email: String }
        guard let account = try? JSONDecoder().decode(Account.self, from: data) else { throw SourceError.readFailed(code: 0) }
        return account.email
    }

    // MARK: Listing

    /// Subfolders of `path` (`""` is the account root), for the in-app browser.
    public func listFolders(path: String) async throws -> [DropboxFolder] {
        try await listAll(path: path, recursive: false)
            .filter { $0.tag == "folder" }
            .compactMap { entry in entry.pathDisplay.map { DropboxFolder(name: entry.name, path: $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Every entry under `path`, following cursors until Dropbox says there is no more.
    func listAll(path: String, recursive: Bool, limit: Int = pageSize) async throws -> [DropboxListEntry] {
        var page = try await listPage("files/list_folder", [
            "path": path, "recursive": recursive, "limit": limit, "include_non_downloadable_files": false,
        ])
        var entries = page.entries
        while page.hasMore {
            page = try await listPage("files/list_folder/continue", ["cursor": page.cursor])
            entries += page.entries
        }
        return entries
    }

    /// One cheap request that proves the folder can be read now.
    func probeFolder(path: String) async throws {
        _ = try await listPage("files/list_folder", ["path": path, "recursive": false, "limit": 1])
    }

    private func listPage(_ endpoint: String, _ body: [String: Any]) async throws -> DropboxListPage {
        let data = try await rpc(endpoint, body: body)
        guard let page = try? JSONDecoder().decode(DropboxListPage.self, from: data) else { throw SourceError.readFailed(code: 0) }
        return page
    }

    // MARK: Download

    /// Streams the file at `path` to `destination`, hashing it (MD5, SHA-256) while it is written.
    public func download(path: String, to destination: URL, control: ExportControl?) async throws -> ExportedFile {
        let header = DropboxArg.header(path: path)
        return try await withRetries { token in
            var request = URLRequest(url: DropboxEndpoint.download)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(header, forHTTPHeaderField: "Dropbox-API-Arg")
            let writer: StreamingFileWriter
            do { writer = try StreamingFileWriter(url: destination, control: control) } catch let failure as StreamingFileWriter.Failure {
                throw Self.map(failure)
            }
            do {
                let head = try await streamer.stream(request) { chunk in
                    if !writer.append(chunk) { throw writer.failure.map(Self.map) ?? SourceError.cancelled }
                }
                guard (200..<300).contains(head.status) else {
                    writer.abort()
                    return .failed(status: head.status, body: head.errorBody, retryAfter: head.retryAfter)
                }
                return .done(try writer.finish())
            } catch {
                writer.abort()
                throw Self.mapThrown(error)
            }
        }
    }

    // MARK: Requests

    private func rpc(_ endpoint: String, body: [String: Any]?) async throws -> Data {
        let payload = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        return try await withRetries { token in
            try await Self.send(Self.rpcRequest(endpoint, token: token, hasBody: payload != nil),
                                body: payload.map { .data($0) } ?? .none, via: transport)
        }
    }

    private static func rpcRequest(_ endpoint: String, token: String, hasBody: Bool = false) -> URLRequest {
        var request = URLRequest(url: DropboxEndpoint.rpc(endpoint))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if hasBody { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private static func send(_ request: URLRequest, body: HTTPBody, via transport: any HTTPTransport) async throws -> Attempt<Data> {
        do {
            let (data, response) = try await transport.send(request, body: body)
            if (200..<300).contains(response.statusCode) { return .done(data) }
            return .failed(status: response.statusCode, body: data, retryAfter: DropboxHTTP.retryAfter(response))
        } catch {
            throw mapThrown(error)
        }
    }

    /// Runs `attempt` with a token. A 401 refreshes the token once; a 429 or 503 waits once for the
    /// time Dropbox names, when that is short.
    private func withRetries<T>(_ attempt: (String) async throws -> Attempt<T>) async throws -> T {
        var forceRefresh = false
        var refreshed = false
        var waited = false
        while true {
            let token = try await tokens.accessToken(forceRefresh: forceRefresh)
            forceRefresh = false
            switch try await attempt(token) {
            case .done(let value):
                return value
            case .failed(let status, let body, let retryAfter):
                if status == 401 {
                    if refreshed { throw SourceError.accessRevoked }
                    refreshed = true
                    forceRefresh = true
                } else if status == 429 || status == 503, !waited, let wait = retryAfter, wait <= Self.maxRetryWait {
                    waited = true
                    do { try await sleep(wait) } catch { throw Self.mapThrown(error) }
                } else {
                    throw Self.error(status: status, body: body)
                }
            }
        }
    }

    // MARK: Errors

    static func error(status: Int, body: Data) -> SourceError {
        switch status {
        case 409: DropboxHTTP.errorSummary(body)?.hasPrefix("path/not_found") == true ? .fileMissing : .readFailed(code: 409)
        case 401, 403: .accessRevoked
        case 429, 500...599: .unavailable
        default: .readFailed(code: status)
        }
    }

    static func map(_ failure: StreamingFileWriter.Failure) -> SourceError {
        switch failure {
        case .stopped: .cancelled
        case .io(let code, _): .readFailed(code: code)
        }
    }

    static func mapThrown(_ error: any Error) -> any Error {
        if let source = error as? SourceError { return source }
        if error is CancellationError { return SourceError.cancelled }
        if let url = error as? URLError { return url.code == .cancelled ? SourceError.cancelled : SourceError.unavailable }
        if let failure = error as? StreamingFileWriter.Failure { return map(failure) }
        return error
    }
}
