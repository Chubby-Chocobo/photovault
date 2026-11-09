import Foundation
import PhotoVaultCore
import PhotoVaultEngine
import PhotoVaultLocal

/// Reads sidecars, hashes and `destination.json` of local and NAS destinations for recovery and
/// integrity checks, through the destination's own no-symlink file access.
struct LocalContentReader: LocalContentReading {
    let registry: DestinationRegistry

    private func local(_ id: DestinationID) async throws -> LocalFolderDestination {
        guard let destination = await registry.destination(for: id) as? LocalFolderDestination else {
            throw DestinationError.notFound
        }
        return destination
    }

    func readSidecar(destination: DestinationID, path: String) async throws -> Data? {
        try await local(destination).readSmallFile(remoteId: path)
    }

    func sha256(destination: DestinationID, path: String) async throws -> String? {
        try await local(destination).contentHash(remoteId: path)
    }

    func archiveTimezone(destination: DestinationID) async throws -> String? {
        try await local(destination).readMarker()?.archiveTimezone
    }
}
