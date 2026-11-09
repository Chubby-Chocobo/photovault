# M0-2: Change history, cloud identifiers, adjustment data and extended metadata

- **Status:** pending owner run
- **Spec refs:** FR-10, FR-12, FR-13, FR-19, FR-46, FR-53, §8.1 (asset key), §6 (macOS target "chốt sau M0-2"), [VERIFY M0-2] at FR-46 and §8.1
- **Owner time:** 2–3 hours. **Wall time:** 2–3 hours.

## Goal

Find out how change history reports inserts, updates and deletes, whether cloud identifiers stay stable, whether adjustment data can be read in Optimize mode, and whether the macOS 27 extended metadata is available.

## Why it matters

The change tracker (spec §8.4, step 2) depends on the change types. The cloud ID decides the asset key (§8.1). The adjustment hash decides whether an edit needs re-exporting (FR-46). The result may also move the deployment target from macOS 14 (spec §6).

## Preconditions

- The probe from [the shared setup](README.md#probe-setup-shared).
- A disposable second Photos library for the rebuild test in step 5. Do not run that step on the main library.

## Procedure

1. Store the current token: `PhotoKitSource().currentChangeToken()`.
2. Make these edits in Photos, one at a time, and note the time of each: import one photo; edit and save a photo; **Revert** that edit; mark a photo as Favorite; hide a photo; add a photo to a regular album; add a photo to a Shared Album (if you have one); take or import a screenshot; record a screen recording (if you can). Delete one test photo.
3. Call `fetchPersistentChanges(since: token)` and print each change: its kind and the local IDs it touches. Note which edits produced an "updated" change and which did not.
4. Export one of the edited assets with `exportResource` and call `fetchPersistentChanges` again. Record whether the export itself produced a change (spec question: does export create "updated"?).
5. Rebuild test (disposable library only): record `cloudIdentifierMappings(localIds:)` for 20 assets. Rebuild or switch to the disposable library and record the same mapping again. Record the cloud IDs' length and whether they match.
6. For 10 edited assets with iCloud-only originals, call `adjustmentDataHash(localId:)`. Record whether a hash comes back and whether it is stable across two calls.
7. On macOS 27 only: check whether `PHAssetExtendedMetadata` and `prefetchAssetExtendedMetadata` exist in the SDK. On macOS 26 record "not in SDK".
8. Album test: confirm that the probe's `albums()` returns regular albums and not Shared Albums.
9. Hidden test: confirm that `fetchAllAssets` returns hidden assets when the probe asks for them (the spec relies on `includeHiddenAssets` and `includeAllBurstAssets`).

## Measure

| Quantity | Expected (from spec or code) | Observed |
|---|---|---|
| Insert change for an import | present | |
| Update change for an edit | present | |
| Update change for Revert | present | |
| Export produces a change | unknown (spec question) | |
| Favorite produces a change | present | |
| Hidden toggle produces a change | present | |
| Cloud ID stable across rebuild | yes | |
| Cloud ID length (characters) | unknown | |
| `adjustmentDataHash` on iCloud-only edit | non-nil, stable | |
| Shared Album assets in `albums()` | no | |
| Extended metadata SDK support | macOS 27 only | |

Duration: 2–3 hours.

## Results

### Owner to fill in

| Step | Result | Notes |
|---|---|---|
| 2 (edits) |  |  |
| 3 (change kinds) |  |  |
| 4 (export produces a change?) |  |  |
| 5 (cloud ID before and after) |  |  |
| 6 (adjustment hash) |  |  |
| 7 (extended metadata) |  |  |
| 8 (Shared Albums) |  |  |
| 9 (hidden assets) |  |  |

Conclusions (free text):

## Changes this result drives

| Setting or constant | File and symbol | Default now |
|---|---|---|
| Token-expiry and change-details errors | `Sources/PhotoVaultPhotos/PhotoKitSource+Changes.swift`, `PhotosErrorMapper.swift` (codes 3105, 3210) | as coded in [0012](../decisions/0012-photos-adapter-defaults.md) item 4–5 |
| Cloud-ID mapping failures | `Sources/PhotoVaultPhotos/PhotoKitSource.swift`, `cloudIdentifierMappings` | failed results skipped |
| Edit gate input | `Sources/PhotoVaultPhotos/PhotoKitSource+Export.swift`, `adjustmentDataHash`; fallback in `Sources/PhotoVaultEngine/EditGate.swift`, `modificationMarker` | `.adjustmentData` hash; `modificationDate` marker when the hash is nil |
| Album scope | `Sources/PhotoVaultPhotos/PhotoKitSource.swift`, `albums()` | regular albums only |
| Hidden upload default | `Sources/PhotoVaultCore/Models/Settings.swift`, `GlobalSettings.includeHidden` | `false` |
| Deployment target | `Config/Base.xcconfig` (`MACOSX_DEPLOYMENT_TARGET`), `Package.swift` (`platforms`) | macOS 14.0 |
| Asset key for `l:` assets | `Sources/PhotoVaultCore/Models/AssetKey.swift` | `c:` when cloud ID is known, else `l:` |

Decisions to update: [0006](../decisions/0006-macos-27-apis-unavailable.md) (target), [0012](../decisions/0012-photos-adapter-defaults.md).
