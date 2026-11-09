# 0013 Google Drive defaults for unverified Drive behaviour

- **Status:** Pending M0 (M0-3, M0-4)
- **Spec refs:** FR-43, FR-44, FR-47, FR-48, FR-103, §8.14, [VERIFY] markers at FR-43, FR-44, FR-47, FR-48, FR-103
- **Review trigger:** after the owner runs M0-3 and M0-4 ([spikes](../spikes/README.md))

## Context

The spec marks these Drive behaviours as unverified (`[VERIFY]`). The implementers chose the defaults below so the code can be built and tested.

## Decision

| # | Default in the code | Location | Spike |
|---|---|---|---|
| 1 | Shortcuts are created under `drive.file` with `generateIds(type=shortcuts)`. A `403` with `insufficientPermissions` or `forbidden` becomes `viewsNotPermitted`, which turns the views off (FR-103). | `GoogleDriveDestination+Views.swift` (`shortcutOperation`), `DriveErrorMapper.swift` (`isForbidden`) | M0-3 |
| 2 | A child of a trashed folder reports `trashed=true`. The folder checks depend on that flag. | `GoogleDriveDestination.swift` (`ensureFolder`, `createVerified`) | M0-3 |
| 3 | A `409` on `files.create` (reused ID) and on starting a resumable session is treated as "already exists", then the item is fetched to check it. | `DriveAPI.swift`, `GoogleDriveDestination.swift` (create-metadata path), `ResumableUploader.swift` | M0-3 |
| 4 | A `308` with no `Range` header after zero bytes means "no bytes stored". A zero-byte file uses `Content-Range: bytes */0`. | `ResumableUploader.swift` | M0-3 |
| 5 | Roots are found by `appProperties.pvRoot` (`findRoots`) so a reinstall with `drive.file` can see them. | `GoogleDriveDestination+Root.swift` | M0-3 |
| 6 | The data-protection Keychain works only in a signed host with a Keychain access group: the `keychain-access-groups` entitlement (`$(AppIdentifierPrefix)com.annh.photovault`) and the provisioning profile that grants it. Without them, even a team-signed build fails with `-34018` (`errSecMissingEntitlement`), and sign-in fails after Google has returned the tokens. | `KeychainStore.swift` | M0-4 |
| 7 | Resumable session URIs are accepted only over `https` on `*.googleapis.com`. | `DriveHTTP.swift` (host check) | M0-3 |
| 8 | The daily cap is 700 × 10⁹ bytes (decimal). See [0016](0016-daily-upload-cap-700gb.md). | `DailyUploadCap.swift` | M0-3 |

Other defaults:

- Chunk size is 8 MiB by default, rounded down to a multiple of 256 KiB (`ResumableUploader.chunkUnit`, `defaultChunkSize`).
- `fields` on metadata calls is `id,name,md5Checksum,trashed,parents,size,appProperties,shortcutDetails,mimeType` (`DriveAPI.fileFields`). The spec asks for `id,md5Checksum,trashed,parents`; the code asks for more.
- The `appProperties` pair limit is 124 bytes (`AppPropertyCodec.maxPairBytes`). Longer values are hashed as `h:` + 32 hex characters (FR-43). The real Drive limit is [VERIFY] in M0-3.

## Consequences

- If M0-3 shows that shortcuts cannot be created under `drive.file`, the views are turned off. The scope is not widened (FR-103).
- The token-bucket rate for Drive writes is not set. See [0017](0017-token-bucket-lanes.md).
