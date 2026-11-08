import Foundation
import PhotoVaultCore
import PhotoVaultDrive

/// The Drive root folder (FR-01 step 3, FR-08): list existing roots, create one, rename it.
struct DriveRootService: Sendable {
    let drive: GoogleDriveDestination

    func existingRoots() async throws -> [RemoteItem] {
        try await drive.findRoots()
    }

    func createRoot(name: String, archiveTimeZone: TimeZone) async throws -> RemoteItem {
        guard let reserved = try await drive.reserveIds(count: 1, kind: .files).first else {
            throw DestinationError.transient(reason: "no id reserved")
        }
        return try await drive.createRoot(
            reservedId: reserved, name: name, appProperties: AppPropertyCodec.rootProperties(archiveTimezone: archiveTimeZone))
    }

    func rename(rootId: String, to name: String) async throws {
        _ = try await drive.renameRoot(remoteId: rootId, newName: name)
    }

    static func webURL(rootId: String) -> URL? {
        URL(string: "https://drive.google.com/drive/folders/\(rootId)")
    }
}
