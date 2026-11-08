# M0-4: Signing, sandbox, Keychain, bookmarks and filesystems

- **Status:** pending owner run
- **Spec refs:** §6 (Signing, entitlements), FR-54, FR-70, FR-73, FR-75, T24, §10 (M0-4)
- **Owner time:** 3–4 hours. **Wall time:** about 2 days, because the Personal Team signing is checked across several rebuilds and a reboot.

## Goal

Check that the app's signing and sandbox setup keeps Photos and folder permissions across rebuilds, that the Keychain item works in a signed build, that a security-scoped bookmark to an SMB share survives remount and reboot, and which atomic-write primitives each filesystem supports.

## Why it matters

Without a stable signature, macOS asks again for Photos and folder access on every build (T24). Bookmarks decide whether a NAS must be re-chosen after a reboot (FR-75). The write primitives decide the placement path for every local file (FR-73).

## Preconditions

- An Apple ID for the Personal Team. Xcode → Settings → Accounts.
- `Config/Local.xcconfig` created from the example, with the Team ID.
- A USB drive formatted as exFAT, and an SMB share from the NAS (mounted in Finder by you).
- The probe from [the shared setup](README.md#probe-setup-shared).

## Procedure

1. **Personal Team signing.** Build the app in Xcode with the Personal Team selected (not "Sign to Run Locally"). Copy `PhotoVault.app` to `/Applications` and run it from there. Grant Photos access when asked.
2. **Rebuild check (T24).** Rebuild and replace the app in `/Applications` three times, with a code change in between. After each rebuild, start the app and record whether macOS asks again for Photos access.
3. **Entitlements.** Run `codesign -d --entitlements :- /Applications/PhotoVault.app` and record the entitlement keys. Confirm `com.apple.security.network.server` is present or absent, as the build set it. Record whether `network.server` is needed: the app makes no inbound connections except the OAuth loopback listener, so test with it removed if the OAuth sign-in still works.
4. **Personal Team lifetime.** Record the expiry date Xcode shows for the Personal Team's profile and certificate, and the date the profile was created. The spec asks how long re-signing lasts.
5. **Keychain in a signed build.** Sign a copy of the probe with the same Personal Team identity. Call `SystemKeychainStore` write, read and delete (`KeychainStore.swift`). Record the result. Then run the same calls from an unsigned probe and record the error (`-34018` is expected).
6. **Bookmark over SMB.** Mount the NAS share in Finder. Create a bookmark with `RootAccess.makeBookmark(for:)` and store its bytes. Unmount the share, remount it, and resolve the bookmark with `RootAccess(bookmark:onRefresh:)`. Record the outcome. Repeat after a reboot.
7. **Stale bookmark.** Move the share to a different mount point (rename the share on the NAS, or mount with a different name), then resolve the old bookmark. Record `bookmarkInvalid` or `offline`.
8. **Write primitives.** On each of APFS (internal disk), exFAT (USB) and SMB (NAS), the probe calls, in a scratch folder: `renameatx_np` with `RENAME_EXCL` (onto an existing name); `link` onto an existing name; `fcntl(F_FULLFSYNC)` on a file. Record success or the `errno` for each. Use the probe's own calls, not the app's code path, so each result is seen directly.
9. **Full write.** Run `LocalFolderDestination(id:root:).testConnection()` and upload one 1 GB file with `upload` to each filesystem. Read the file back and compare SHA-256. Record the time.
10. **Symlink check.** Create a symlink named `.photovault` in a test root, then call `checkAvailability()`. Record the status (expected `paused(rootMissing)`). Remove the symlink.

## Measure

| Quantity | Expected | Observed |
|---|---|---|
| Photos access re-asked after rebuild | no | |
| Entitlement keys | as in `Config/PhotoVault.entitlements` | |
| Keychain write/read in signed probe | works | |
| Keychain error in unsigned probe | `-34018` | |
| Bookmark after remount | resolves | |
| Bookmark after reboot | resolves | |
| `RENAME_EXCL` on APFS, exFAT, SMB | supported | |
| `link` on APFS, exFAT, SMB | supported | |
| `F_FULLFSYNC` on APFS, exFAT, SMB | supported (or `ENOTSUP`) | |
| 1 GB round trip SHA-256 equal | yes | |

Duration: 3–4 hours hands-on, about 2 days wall time.

## Results

### Owner to fill in

| Step | APFS | exFAT | SMB | Notes |
|---|---|---|---|---|
| 2 (rebuilds, Photos prompt) |  |  |  |  |
| 3 (entitlements, `network.server`) |  |  |  |  |
| 4 (Personal Team expiry) |  |  |  |  |
| 5 (Keychain, signed and unsigned) |  |  |  |  |
| 6 (bookmark after remount and reboot) |  |  |  |  |
| 7 (stale bookmark) |  |  |  |  |
| 8 (`RENAME_EXCL`, `link`, `F_FULLFSYNC`) |  |  |  |  |
| 9 (1 GB round trip, seconds) |  |  |  |  |
| 10 (symlinked `.photovault`) |  |  |  |  |

Conclusions (free text):

## Changes this result drives

| Setting or constant | File and symbol | Default now |
|---|---|---|
| `network.server` entitlement | `Config/PhotoVault.entitlements` | present |
| Team ID | `Config/Local.xcconfig` (`DEVELOPMENT_TEAM`), from `Config/Local.xcconfig.example` | placeholder |
| Keychain attributes | `Sources/PhotoVaultDrive/KeychainStore.swift`, `SystemKeychainStore.query` | [0010](../decisions/0010-keychain-class.md) |
| Bookmark handling | `Sources/PhotoVaultLocal/RootAccess.swift`, `makeBookmark(for:)`, the stale-bookmark path | refresh, else `bookmarkInvalid` |
| Rename fallback order | `Sources/PhotoVaultLocal/DirectoryHandle.swift`, `renameExclusive` | `RENAME_EXCL`, then `link`, then check-then-rename under the folder lock |
| Data sync | `Sources/PhotoVaultLocal/AtomicFileWriter.swift`, `flush` | `F_FULLFSYNC`, then `fsync` |
| Container path | `Sources/PhotoVaultEngine/ContainerLocator.swift` | [0009](../decisions/0009-sandbox-container.md) |

Decisions to update: [0009](../decisions/0009-sandbox-container.md), [0010](../decisions/0010-keychain-class.md), [0013](../decisions/0013-drive-defaults.md) (item 6), [0014](../decisions/0014-local-nas-defaults.md).
