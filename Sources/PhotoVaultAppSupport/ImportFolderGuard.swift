import Foundation
import PhotoVaultCore

/// A folder to import from must not be, hold or sit inside a local destination, or the app's own data folder:
/// the import would read the backup it writes, or the app's staging files.
public enum ImportFolderGuard {
    /// Owner-facing reason to refuse `candidate`, or nil when it is fine.
    public static func conflict(candidate: String, destinations: [(name: String, path: String)], container: String) -> String? {
        if let hit = DestinationNesting.conflict(candidate: candidate, existing: destinations) {
            switch hit.relation {
            case .same, .inside:
                return tr(vi: "Thư mục này là hoặc nằm trong đích “\(hit.name)”. Hãy chọn thư mục ảnh khác.", en: "This folder is, or is inside, the destination “\(hit.name)”. Choose another folder of photos.")
            case .contains:
                return tr(vi: "Thư mục này chứa đích “\(hit.name)”. Hãy chọn thư mục ảnh khác.", en: "This folder contains the destination “\(hit.name)”. Choose another folder of photos.")
            }
        }
        if DestinationNesting.relation(of: candidate, to: container) != nil {
            return tr(vi: "Thư mục này là hoặc chứa dữ liệu của PhotoVault. Hãy chọn thư mục ảnh khác.", en: "This folder is, or contains, PhotoVault's own data. Choose another folder of photos.")
        }
        return nil
    }
}
