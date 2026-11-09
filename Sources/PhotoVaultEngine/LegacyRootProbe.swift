import Foundation
import PhotoVaultCore

/// Tells whether a PhotoVault root at a destination holds a backup in the old `YYYY/MM` layout.
///
/// The old layout put camera photos in year folders straight under the root (`2026/11/…`) and
/// screenshots and saved images in year folders under `Screenshots` and `Saved`. The current layout
/// has `Camera Uploads/YYYY-MM-DD` instead, so such a root cannot be reused: adopting it would move
/// every file, or export everything a second time. The probe reads folder names one level deep.
public enum LegacyRootProbe {
    /// Folder names directly under a path inside the root: `[]` is the root, `["Screenshots"]` that branch.
    public typealias ChildFolders = @Sendable (_ path: [String]) async throws -> [String]

    private static let oldBranches = [DynamicLayout.screenshotsName, DynamicLayout.savedName]

    /// A year folder of the old layout: exactly four digits.
    public static func isYearFolderName(_ name: String) -> Bool {
        name.utf8.count == 4 && name.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    public static func hasLegacyContent(_ children: ChildFolders) async throws -> Bool {
        let top = try await children([])
        if top.contains(where: isYearFolderName) { return true }
        for branch in oldBranches where top.contains(branch) {
            if try await children([branch]).contains(where: isYearFolderName) { return true }
        }
        return false
    }

    /// The same test on the logical path stored with a folder (`camera/2026`, `screenshot/2026/11`).
    static func isLegacyLogicalPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        return parts.count >= 2 && ["camera", "screenshot", "saved"].contains(parts[0]) && isYearFolderName(parts[1])
    }

    /// The same test on the display path of a folder found in a full listing.
    static func isLegacyFolder(displayPath: String) -> Bool {
        let parts = displayPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first else { return false }
        if parts.count == 1 { return isYearFolderName(first) }
        return oldBranches.contains(first) && isYearFolderName(parts[1])
    }
}
