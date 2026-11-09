import Foundation
import PhotoVaultCore
import PhotoVaultDrive
import PhotoVaultEngine

/// The Drive root folder (FR-01 step 3, FR-08): list existing roots, create one, rename it.
struct DriveRootService: Sendable {
    let drive: GoogleDriveDestination

    func existingRoots() async throws -> [RemoteItem] {
        try await drive.findRoots()
    }

    /// True when the root holds a 0.1.0 backup (year folders): it cannot be reused. A listing that fails
    /// counts as "no": recovery looks at the whole root again and refuses it.
    func holdsOldLayout(rootId: String) async -> Bool {
        let drive = drive
        let found = try? await LegacyRootProbe.hasLegacyContent { path in
            var parent = rootId
            for name in path {
                guard let next = try await drive.childFolders(of: parent).first(where: { $0.name == name }) else { return [] }
                parent = next.remoteId
            }
            return try await drive.childFolders(of: parent).map(\.name)
        }
        return found ?? false
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
