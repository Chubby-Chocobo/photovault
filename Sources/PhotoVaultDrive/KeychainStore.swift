import Foundation
import PhotoVaultCore
import Security

/// Secret storage for the Google refresh token (NFR-06). Throws `DestinationError` only.
public protocol KeychainStore: Sendable {
    /// nil when no item exists.
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    /// Deleting a missing item is not an error.
    func delete(account: String) throws
}

/// Data-protection keychain item: no ACL prompts across rebuilds, never leaves this Mac.
public struct SystemKeychainStore: KeychainStore {
    public static let service = "com.annh.photovault.google"

    private let serviceName: String

    public init(service: String = SystemKeychainStore.service) { serviceName = service }

    static func query(account: String, service: String = SystemKeychainStore.service) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
    }

    public func read(account: String) throws -> Data? {
        var query = Self.query(account: account, service: serviceName)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try Self.check(status)
        return result as? Data
    }

    public func write(_ data: Data, account: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(Self.query(account: account, service: serviceName) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            try Self.check(SecItemAdd(Self.query(account: account, service: serviceName).merging(attributes) { $1 } as CFDictionary, nil))
        } else {
            try Self.check(status)
        }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(Self.query(account: account, service: serviceName) as CFDictionary)
        if status != errSecItemNotFound { try Self.check(status) }
    }

    static func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound: throw DestinationError.reauthRequired
        case errSecInteractionNotAllowed: throw DestinationError.transient(reason: "keychain locked")
        default: throw DestinationError.transient(reason: "keychain status \(status)")
        }
    }
}
