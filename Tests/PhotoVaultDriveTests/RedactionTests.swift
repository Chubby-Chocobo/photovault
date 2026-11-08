import Foundation
import Testing
import PhotoVaultCore
import PhotoVaultTestSupport
@testable import PhotoVaultDrive

@Suite struct RedactionTests {
    @Test func noSecretReachesTheLogs() async throws {
        let sink = RecordingLogSink()
        let clock = FixedClock()
        let idToken = TestJWT.make(extra: ["secretClaim": "SENTINEL-IDTOKEN"], now: clock.now)
        let verifier = VerifierBox()
        let oauthStub = StubTransport { r in
            if r.url.path == "/token" {
                if let v = r.form["code_verifier"] { verifier.set(v) }
                let fresh = r.form["grant_type"] == "refresh_token"
                var body: [String: Any] = ["access_token": fresh ? "SENTINEL-ACCESS-2" : "SENTINEL-ACCESS-1", "expires_in": 30, "scope": "https://www.googleapis.com/auth/drive.file"]
                if !fresh { body["refresh_token"] = "SENTINEL-REFRESH"; body["id_token"] = idToken }
                return .json(200, body)
            }
            return StubResponse(status: 200)
        }
        let server = FakeDriveServer(sessionPrefix: "SENTINEL-SESSION")
        let transport = LoggingHTTPTransport(wrapping: RouterTransport(oauth: oauthStub, drive: server), log: sink)
        let opener: URLOpening = { url in
            let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            Task { _ = try? await URLSession.shared.data(from: URL(string: "\(items["redirect_uri"]!)?code=SENTINEL-CODE&state=\(items["state"]!)")!) }
            return true
        }
        let oauth = OAuthClient(config: OAuthConfig(clientID: "client-1", clientSecret: "SENTINEL-CLIENT-SECRET"),
                                transport: transport, clock: clock, openURL: opener)
        let keychain = InMemoryKeychainStore()
        let auth = GoogleAuthSession(oauth: oauth, keychain: keychain, clock: clock, log: sink)
        _ = try await auth.signIn()
        #expect(keychain.refreshToken == "SENTINEL-REFRESH")

        clock.advance(120)  // access token expired: forces a refresh on the next call
        let destination = GoogleDriveDestination(transport: transport, auth: auth, chunkSize: 256 * 1024, clock: clock, log: sink)
        let rootId = try await destination.reserveIds(count: 1, kind: .files)[0]
        let root = try await destination.createRoot(reservedId: rootId, name: "R", appProperties: [:])
        let scratch = try tempDir()
        let content = try TestFiles.staged(payload(400 * 1024), in: scratch)
        let request = UploadRequest(job: JobIdentity(destinationId: .googleDrive, assetKey: .local("A"), resType: .photo), jobId: 1, kind: .original,
                                    reservedRemoteId: try await destination.reserveIds(count: 1, kind: .files)[0],
                                    parent: .root(remoteId: root.remoteId), fileName: "SENTINEL-FILENAME.HEIC", content: content)
        let checkpoint = Events()
        _ = try await destination.upload(request) { checkpoint.add($0.sessionRef); sink.log(.info, category: "test", "\($0)") }
        try await auth.signOut()

        let log = sink.lines.joined(separator: "\n")
        #expect(sink.lines.count > 5 && log.contains("googleapis.com"))
        let secrets = ["SENTINEL-REFRESH", "SENTINEL-ACCESS-1", "SENTINEL-ACCESS-2", "SENTINEL-CODE", "SENTINEL-CLIENT-SECRET",
                       idToken, "SENTINEL-SESSION", "upload_id", "SENTINEL-FILENAME", verifier.value ?? "<missing>", "Bearer", "code_challenge"]
        for secret in secrets { #expect(!log.contains(secret), "log leaked \(secret.prefix(12))") }
        #expect(checkpoint.all[0].contains("SENTINEL-SESSION"))  // the secret really was in play
        #expect(verifier.value?.count == 64)
    }

    @Test func pathTemplateHidesIds() {
        #expect(PathTemplate.make("/drive/v3/files/1AbCdEf") == "/drive/v3/files/:id")
        #expect(PathTemplate.make("/upload/drive/v3/files") == "/upload/drive/v3/files")
        #expect(PathTemplate.make("/drive/v3/files/generateIds") == "/drive/v3/files/generateIds")
    }

    @Test func tokenAndCheckpointDescriptionsAreRedacted() {
        let tokens = OAuthTokens(accessToken: "SENTINEL-A", refreshToken: "SENTINEL-R", expiresAt: Date(), idToken: nil)
        #expect(!"\(tokens)".contains("SENTINEL"))
        #expect(!"\(SessionCheckpoint(sessionRef: "SENTINEL-S", md5: "m", totalBytes: 1))".contains("SENTINEL"))
    }
}

final class VerifierBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    func set(_ v: String) { lock.withLock { stored = v } }
    var value: String? { lock.withLock { stored } }
}
