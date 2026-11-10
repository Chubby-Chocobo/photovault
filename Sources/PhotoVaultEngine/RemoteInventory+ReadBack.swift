import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// What recovery keeps of a sidecar it read back from Drive: only the fields it restores.
struct ReadBackFacts: Codable, Sendable, Equatable {
    struct Resource: Codable, Sendable, Equatable {
        var backupName: String
        var md5: String?
        var sha256: String?
    }

    var camera: SidecarDocument.Camera?
    var resources: [Resource]

    init(_ document: SidecarDocument) {
        camera = document.camera
        resources = document.resources.map { Resource(backupName: $0.backupName, md5: $0.md5, sha256: $0.sha256) }
    }
}

extension RemoteInventoryLoader {
    /// Tries per sidecar for a throttled, failing or dropped read before it is given up on.
    static let readAttempts = 4
    /// This many sidecars in a row given up on means the destination is not answering: recovery stops and
    /// runs again later instead of spending the whole library's worth of failing reads.
    static let consecutiveGiveUps = 10
    private static let longestWait: TimeInterval = 60

    /// The database loss took the hashes and camera fields the sidecars list, and Drive does not report
    /// them. The JSON sidecars this app wrote are read back, one small download at a time, and give them
    /// to the files they describe. Each answer is kept (keyed by file id and md5) until the inventory is
    /// complete, so a restart does not read a sidecar twice. A read is retried with backoff, honouring
    /// `Retry-After`. A sidecar that cannot be read (gone, foreign, corrupt, or failing for good) is
    /// skipped: it is written again once, because what the app builds then differs from it. Offline and
    /// sign-in errors, or a run of skipped sidecars, stop the recovery; nothing has been written by then.
    func restoreFromSidecars(_ files: inout [RemoteFileEntry]) async throws {
        guard let reader = destination as? any SmallFileReading else { return }
        var facts: [String: [ReadBackFacts]] = [:]
        var giveUps = 0
        for entry in files where entry.resType == .sidecarJson && !entry.item.trashed {
            try Task.checkCancellation()
            guard (entry.item.size ?? 0) <= Self.maxSidecarBytes else { continue }
            let found: ReadBackFacts?
            do {
                found = try await readBack(entry.item, with: reader)
                giveUps = 0
            } catch let error as DestinationError where Self.isHiccup(error) {
                giveUps += 1
                env.log.log(.notice, category: "recovery", "destination=\(record.id) skipped a sidecar that could not be read back")
                if giveUps >= Self.consecutiveGiveUps { throw error }
                continue
            }
            if let found { facts[entry.parentFolderId ?? "", default: []].append(found) }
        }
        try await forgetReadBack()
        guard !facts.isEmpty else { return }
        for index in files.indices where files[index].resType?.isSidecar == false {
            let name = files[index].item.name
            guard let hit = (facts[files[index].parentFolderId ?? ""] ?? []).lazy.compactMap({ item in
                item.resources.first { $0.backupName == name }.map { (item, $0) }
            }).first else { continue }
            files[index].contentMd5 = files[index].contentMd5 ?? hit.1.md5
            files[index].contentSha256 = files[index].contentSha256 ?? hit.1.sha256
            files[index].camera = hit.0.camera
        }
    }

    private static func isHiccup(_ error: DestinationError) -> Bool {
        switch error {
        case .rateLimited, .server, .transient: true
        default: false
        }
    }

    /// One sidecar: from the kept answer, else downloaded. nil when it is not usable. Throws a hiccup that
    /// outlasted the retries, or any error that is not a hiccup (offline, sign-in).
    private func readBack(_ item: RemoteItem, with reader: any SmallFileReading) async throws -> ReadBackFacts? {
        let key = item.md5.map { "readback:\(record.id.rawValue):\(item.remoteId):\($0)" }
        let store = env.store
        if let key, let kept = try await store.read({ db in try KeyValueRepository.data(db, key) }),
           let facts = try? JSONDecoder().decode(ReadBackFacts.self, from: kept) {
            return facts
        }
        var attempt = 0
        while true {
            do {
                let data = try await reader.readSmallFile(remoteId: item.remoteId, maxBytes: Int(Self.maxSidecarBytes))
                guard let data, let document = SidecarDocument.parse(data) else { return nil }
                let facts = ReadBackFacts(document)
                if let key, let encoded = try? JSONEncoder().encode(facts) {
                    try await store.write { db in try KeyValueRepository.set(db, key, encoded) }
                }
                return facts
            } catch let error as DestinationError where Self.isHiccup(error) {
                attempt += 1
                if attempt >= Self.readAttempts { throw error }
                var wait = Backoff(base: 1, cap: Self.longestWait).delay(forAttempt: attempt - 1)
                if case .rateLimited(let retryAfter?) = error { wait = max(wait, min(retryAfter, Self.longestWait)) }
                try await env.tuning.sleep(wait)
            }
        }
    }

    /// The inventory is complete: the kept answers are no longer needed.
    private func forgetReadBack() async throws {
        let prefix = "readback:\(record.id.rawValue):"
        try await env.store.write { db in
            try db.execute(sql: "DELETE FROM kv WHERE substr(key, 1, ?) = ?", arguments: [prefix.count, prefix])
        }
    }
}
