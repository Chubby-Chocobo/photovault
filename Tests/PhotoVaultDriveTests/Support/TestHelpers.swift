import Foundation
import PhotoVaultCore
@testable import PhotoVaultDrive

final class InMemoryKeychainStore: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    init(refreshToken: String? = nil) {
        if let refreshToken { items[GoogleAuthSession.refreshAccount] = Data(refreshToken.utf8) }
    }

    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return items[account] }
    func write(_ data: Data, account: String) throws { lock.lock(); items[account] = data; lock.unlock() }
    func delete(account: String) throws { lock.lock(); items[account] = nil; lock.unlock() }
    var refreshToken: String? {
        (try? read(account: GoogleAuthSession.refreshAccount)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

final class FixedClock: PhotoVaultCore.Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = date }
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
}

actor StaticAuth: DriveAuthorizing {
    private(set) var refreshes = 0
    func accessToken() async throws -> String { "static-token" }
    func refreshAfterUnauthorized(rejected: String) async throws -> String { refreshes += 1; return "static-token-2" }
}

enum TestJWT {
    static func make(aud: String = "client-1", iss: String = "https://accounts.google.com", exp: Double? = nil,
                     sub: String = "sub-123", email: String = "a@example.com", extra: [String: Any] = [:],
                     now: Date = FixedClock().now) -> String {
        var claims: [String: Any] = ["aud": aud, "iss": iss, "exp": exp ?? now.timeIntervalSince1970 + 3600,
                                     "sub": sub, "email": email]
        claims.merge(extra) { $1 }
        let payload = try! JSONSerialization.data(withJSONObject: claims)
        return ["e30", Base64URL.encode(payload), "c2ln"].joined(separator: ".")
    }
}

func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pvdrive-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
