# M0-3: Google Drive behaviour under drive.file

- **Status:** pending owner run
- **Spec refs:** FR-02, FR-43, FR-44, FR-47, FR-48, FR-49, FR-103, §8.14, §8.15, §10 (M0-3), [VERIFY] markers at FR-43, FR-44, FR-47, FR-48, FR-49, FR-103, FR-08
- **Owner time:** 3–4 hours. **Wall time:** about 1 day, mostly the upload runs.

## Goal

Check what Drive really does with the `drive.file` scope: resumable uploads through sleep and network loss, shortcuts, ID reservation and collisions, quota, `appProperties` limits, folder trash and recovery after reinstall, and the sustained write rate.

## Why it matters

Several defaults depend on these answers: the views (FR-103), the daily cap (FR-49), the token bucket rate (FR-49), the `appProperties` hashing rule (FR-43), and the recovery path after reinstall (FR-51, §8.15).

## Preconditions

- The probe from [the shared setup](README.md#probe-setup-shared), with `PhotoVaultDrive` linked.
- A Google account (the owner's) and an OAuth Desktop client set up as in [the README](../../README.md#google-cloud-setup).
- A 4 GB random test file, created with `mkfile 4g` or similar, outside the repo.
- A disposable test root folder in Drive, named for the spike.

## Procedure

1. **Sign in.** Build `OAuthClient` and `GoogleAuthSession` (see the initialisers in `Sources/PhotoVaultDrive/OAuthClient.swift` and `GoogleAuthSession.swift`) and call `signIn()`. Record the scopes the token response carries. The app must not ask for a wider scope.
2. **Resumable upload.** Upload the 4 GB file with `GoogleDriveDestination.upload`. Turn Wi-Fi off for 60 seconds at about 30% progress, then turn it on. Put the Mac to sleep for 10 minutes at about 60%, then wake it. Record whether the session survives, and whether `resumeUpload` continues from the offset Drive reports. Check the final `md5Checksum` against the local MD5.
3. **Zero-byte upload.** Upload an empty file. Record the `Content-Range` the probe sends (`bytes */0`) and the response code.
4. **Quota.** Call `quota()`. Record the reported limit and usage. Check whether the value matches Drive's storage page.
5. **Shortcuts.** Call `reserveIds(count:kind:)` with `.shortcuts`. Then `createShortcut(_:)` to a target file. Then `moveShortcut(remoteId:from:to:)`. Then `trashShortcut(remoteId:)`. Then `untrash` on the shortcut through the probe (it is defined on `GoogleDriveDestination+Root.swift` for root items; record the result for a shortcut, whatever it is). Record each response code.
6. **Forbidden shortcuts.** If any shortcut call returns `403`, record the response body. The code maps it to `viewsNotPermitted`.
7. **ID collision.** Create a shortcut with a reserved ID, then create another with the same ID. Record the code (expected `409`) and whether the probe treats it as "already exists".
8. **Child of a trashed folder.** Trash a test folder. Then call `ensureFolder` for a child of it. Record whether the child reports `trashed=true`.
9. **appProperties limit.** Set a key and value whose combined UTF-8 length is 124 bytes, then 125, with `updateMetadata(remoteId:description:appProperties:)`. Record which is rejected.
10. **Reinstall recovery.** Delete the probe's local state (or use a fresh probe directory), then call `findRoots()`. Record whether the test root is found by `appProperties.pvRoot`.
11. **Sustained write rate.** Upload a 1 GB file, then 10 more 100 MB files back to back, for 10 minutes. Record MB per minute and the number of write requests per minute. Record any `429` or `5xx`, and the `Retry-After` header if present.
12. **Versions.** Upload the same file twice with `replaceContent`. In Drive's web UI, open the file's version list and record how many versions exist (the spec asks about revisions and the 30-day rule).

## Measure

| Quantity | Expected (spec or code) | Observed |
|---|---|---|
| Scopes in token response | `drive.file openid email` | |
| Session survives sleep and network loss | yes | |
| Final MD5 equals local MD5 | yes | |
| Zero-byte upload | `bytes */0` accepted | |
| Quota fields | `about.get storageQuota` | |
| Shortcut create, move, trash | succeed under `drive.file` | |
| Shortcut `untrash` | unknown | |
| `403` on shortcut calls | not expected | |
| Reused ID | `409` | |
| Child of trashed folder `trashed` | `true` | |
| appProperties pair at 124 bytes | accepted | |
| Root found after reinstall | yes | |
| Sustained writes per minute | unknown | |
| Drive versions after two replaces | unknown | |

Duration: 3–4 hours hands-on, about 1 day wall time.

## Results

### Owner to fill in

| Step | Result | Response codes or notes |
|---|---|---|
| 1 (scopes) |  |  |
| 2 (resumable with sleep and network loss) |  |  |
| 3 (zero-byte) |  |  |
| 4 (quota) |  |  |
| 5 (shortcut operations) |  |  |
| 6 (403 on shortcuts) |  |  |
| 7 (ID collision) |  |  |
| 8 (child of trashed folder) |  |  |
| 9 (appProperties, 124 and 125 bytes) |  |  |
| 10 (reinstall recovery) |  |  |
| 11 (sustained writes, MB/min and requests/min) |  |  |
| 12 (versions) |  |  |

Conclusions (free text):

## Changes this result drives

| Setting or constant | File and symbol | Default now |
|---|---|---|
| Views on or off | `Sources/PhotoVaultCore/Models/Settings.swift`, `GlobalSettings.viewByDeviceEnabled`, `viewByPlaceEnabled`, `viewFavoritesEnabled` | `true`. If shortcuts are refused, set these to `false` (FR-103); do not widen the scope |
| 403 mapping | `Sources/PhotoVaultDrive/GoogleDriveDestination+Views.swift`, `shortcutOperation` | `viewsNotPermitted` |
| Daily cap | `Sources/PhotoVaultDrive/DailyUploadCap.swift`, `DailyUploadCap.defaultLimit` | 700 × 10⁹ bytes |
| Drive write rate | `Sources/PhotoVaultCore/Policies/TokenBucket.swift`, `TokenBucket(capacity:refillPerHour:)` (not yet constructed for Drive) | unset |
| appProperties pair limit | `Sources/PhotoVaultCore/Codecs/AppPropertyCodec.swift`, `AppPropertyCodec.maxPairBytes` | 124 |
| Upload chunk size | `Sources/PhotoVaultDrive/ResumableUploader.swift`, `defaultChunkSize` | 8 MiB |

Decisions to update: [0013](../decisions/0013-drive-defaults.md), [0016](../decisions/0016-daily-upload-cap-700gb.md), [0017](../decisions/0017-token-bucket-lanes.md).
