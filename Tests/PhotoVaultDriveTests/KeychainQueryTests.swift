import PhotoVaultCore
import Security
import Testing
@testable import PhotoVaultDrive

@Suite struct KeychainQueryTests {
    @Test func queryTargetsThePrivateDataProtectionKeychain() {
        let q = SystemKeychainStore.query(account: "refresh-token")
        #expect(q[kSecAttrService as String] as? String == "com.annh.photovault.google")
        #expect(q[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(q[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(q[kSecClass as String] as? String == kSecClassGenericPassword as String)
    }

    @Test func theListingQueryReadsEveryItemOfTheServiceWithoutSecrets() {
        let q = SystemKeychainStore.listQuery()
        #expect(q[kSecAttrService as String] as? String == "com.annh.photovault.google")
        #expect(q[kSecAttrAccount as String] == nil)
        #expect(q[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String)
        #expect(q[kSecReturnAttributes as String] as? Bool == true)
        #expect(q[kSecReturnData as String] == nil)
    }

    @Test func statusMapping() {
        #expect(throws: DestinationError.transient(reason: "keychain locked")) { try SystemKeychainStore.check(errSecInteractionNotAllowed) }
        #expect(throws: DestinationError.reauthRequired) { try SystemKeychainStore.check(errSecItemNotFound) }
        #expect(throws: Never.self) { try SystemKeychainStore.check(errSecSuccess) }
    }
}
