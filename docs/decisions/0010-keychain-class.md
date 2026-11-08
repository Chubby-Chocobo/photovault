# 0010 Data-protection Keychain, this device only, not synchronizable

- **Status:** Accepted (review later)
- **Spec refs:** FR-03, NFR-06, §9, T24
- **Review trigger:** when M0-4 shows the data-protection Keychain fails in a signed build

## Context

The refresh token must be stored in the Keychain (FR-03). A legacy file Keychain item with an ACL asks for a password after rebuilds, which breaks T24 (no permission prompts after rebuild).

## Decision

`SystemKeychainStore` (`KeychainStore.swift`) writes one generic-password item:

| Attribute | Value |
|---|---|
| `kSecAttrService` | `com.annh.photovault.google` |
| `kSecAttrAccount` | `refresh-token` (`GoogleAuthSession.refreshAccount`) |
| `kSecUseDataProtectionKeychain` | `true` |
| `kSecAttrSynchronizable` | `false` |
| `kSecAttrAccessible` | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |

Access tokens are kept in memory only (`GoogleAuthSession`).

## Consequences

- The item never leaves this Mac and is not in iCloud Keychain.
- Items in the data-protection Keychain need a signed host. Unsigned builds fail with `-34018` (recorded in [0013](0013-drive-defaults.md), item 6).
- Sign-out deletes the item first, then revokes the token best-effort (`GoogleAuthSession.signOut`).
