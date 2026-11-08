import Foundation

/// Namespace for the PhotoVault core module.
public enum PhotoVaultCoreModule {
    public static let name = "PhotoVaultCore"
    /// Bundle identifier; TCC permissions are bound to it (spec header).
    public static let bundleIdentifier = "com.annh.photovault"
    /// Resource bundle holding `device-names.json`.
    public static var resources: Bundle { .module }
}
