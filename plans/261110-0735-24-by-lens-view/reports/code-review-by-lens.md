# Code review: By lens view (issue #24)

Scope: `git diff origin/release/0.4.0...4d3f50f` (19 files, +318/-7). Checks ran in a throwaway worktree at 4d3f50f, which was removed afterwards.

## Checks run

- `swift test` (full suite) at 4d3f50f: **1210 tests in 202 suites passed**.
- Release `xcodebuild` of the app scheme: **BUILD SUCCEEDED** (no errors; `CODE_SIGNING_ALLOWED=NO`).
- Engine probe (`ZZAuditLensTests`, scratch only): a Sony asset with lens `FE 24-70` is backed up first, then an asset with `fe 24-70`, then a second `FE 24-70`.
- Normaliser probe: `LensNameResolver` + `NameSanitizer` compiled standalone and run on 28 realistic `LensModel` strings.

## Critical

None.

## Important

### I1. Lens folders are renamed back and forth; the "never renames" claim is false

`syncFolderNames` skips By lens, but `ViewExecutor.create` and `ViewExecutor.move` still call `queueRenames(chain)` (`Sources/PhotoVaultEngine/ViewExecutor.swift:99` and `:139`). For the lens level that compares the stored folder name with the name of the shortcut being created now. Probe result:

```
step1  By lens/FE 24-70                       renames: []
step2  By lens/fe 24-70      renames: FE 24-70 -> fe 24-70 [done]
step3  By lens/FE 24-70      renames: ... fe 24-70 -> FE 24-70 [done]
```

So every new shortcut whose spelling differs only in case from the folder's current name renames the folder. With a mixed library (photos from the camera and from an editor that writes different case), the folder flips on every batch. This costs Drive API calls and shows up as rename churn in Drive activity. The skip also leaves the result order-dependent. ADR 0027 ("the app never renames a lens folder"), FR-107 ("Tên thư mục giữ như lúc tạo") and the code comment on `syncFolderNames` all describe behaviour the code does not have. The skip covers only one of the three call sites, so its stated reason does not hold.

Fix: do the skip inside `queueRenames` so it covers all three call sites. For example, pass the view and skip levels under `view/byLens/` when `view == .byLens`, or skip the group level whenever `chain.first?.logicalPath == "view/byLens"`. Then drop the `where` in `syncFolderNames`. Add an engine test with two case variants: the folder keeps the first name, and no `renameFolder` job is queued. The probe above can serve as that test; it needs a metadata stub that returns a lower-case lens.

### I2. Every Apple and Pixel lens folder shows `f_1.78`, not the `f/1.78` the owner approved

`NameSanitizer` (FR-42) maps `/` to `_`. Every Apple string ends in `f/<aperture>`, so the real Drive folder is `iPhone 15 Pro 6.86mm f_1.78`. The issue #24 comment the owner agreed to, README (`README.md:167`, "iPhone 15 Pro 6.86mm f/1.78") and the plan all show `f/1.78`. The unit test `layoutChainIsViewLensDay` shows that someone knew about `/` → `_`, but no owner-facing text says so. The most common case for this owner (iPhone) gets the least readable name.

Options:
- (a) In `LensNameResolver`, rewrite the aperture `f/N` to `fN`, e.g. `iPhone 15 Pro 6.86mm f1.78`, which matches how Sony and Canon write `F2.8`.
- (b) Keep `_` and correct README, FR-107 and ADR 0027, telling the owner.

Decide **before release**: the grouping key is a hash of the normalised name, so changing the normaliser after release moves every lens shortcut (see M1). Option (a) changes the name, the key and a test; it is a small change. It is the owner's call because the approved examples show `/`. Recommend (a), confirmed with the owner.

## Minor

### M1. Changing the normaliser later moves shortcuts and leaves empty folders on Drive

This answers the question of whether a lens folder name ever needs to change. `key = hash(lowercased(normalisedName))`, so any later change to the normaliser (I2(a), a Pixel or iPad rule, NFC) produces new keys. Every affected shortcut is then moved to a new group folder by `ViewDiff`, and the old group folders stay on Drive empty: nothing in `Sources/` trashes view folders. A rename is never what is needed, so the `syncFolderNames` skip itself is safe. The exception is a sanitizer-only change that keeps the key; with the skip (once I1 is fixed) the folder keeps its old name, which is acceptable. ADR 0027 Consequences should say: "changing the name rule in a later release moves lens shortcuts into new folders; the old folders stay, empty".

### M2. Key is computed before sanitising and NFC

`LensNameResolver.key` hashes `name.lowercased()`, but the folder name is `NameSanitizer.sanitize(name)`, which applies NFC, removes format characters and maps forbidden characters to `_`. Two strings that differ only in NFC/NFD form, a zero-width character or a forbidden character (e.g. `f/1.8` vs `f:1.8`) get different keys but the same folder name: two sibling folders with the same name under `By lens/`. This is rare in EXIF. Cheap fix: hash the lowercased NFC form of the sanitised name, before anyone relies on the keys (pre-release).

### M3. Placeholder lens strings become folders

Some bodies and adapters write placeholder values. The normaliser keeps them, so you get folders named `----` or `0.0 mm f_0.0`. Sony writes `----` for adapted or manual lenses; `0.0 mm f/0.0` comes from lenses that report no data. Consider treating values that have no letters or digits, and the `0.0 mm f/0.0` pattern, as missing, in line with the "no Unknown folder" decision. The owner's call; low priority.

### M4. Docs: smaller inaccuracies

- FR-103's last bullet (`docs/requirements/photovault-spec-v1.md:350`) still lists "(By device, Favorites, By place)"; By lens is missing.
- ADR 0027 and FR-107 describe the shortening as Apple-only, but the regex also shortens Android strings in the same format, e.g. `Pixel 7 Pro back camera 6.81mm f/1.85` → `Pixel 7 Pro 6.81mm f/1.85`. That is harmless and probably wanted; say so.
- `ViewKind` and `ViewRules` doc comments still say "FR-104..106" (`OrganizationRecords.swift:129`, `ViewRules.swift:29`).
- `docs/design/mockups/settings.html:479`: the rebuild dialog text lists only three views. It is a mockup, so optional.
- Downgrade: a 0.3.0 binary cannot decode `shortcut.view = 'byLens'` rows. This has the same no-downgrade posture as ADR 0026; one line in ADR 0027 would record it.

## Verified OK

- **Normaliser on real strings.** These all shorten as intended: iPhone back wide, ultra wide and telephoto (`… back triple camera 15.66mm f/2.8` → `iPhone 15 Pro 15.66mm f/2.8`); front and TrueDepth (`iPhone X front 2.87mm f/2.2`); `iSight Duo`; `dual wide`; iPad and iPad Pro names with parentheses; SE generations. Strings with no focal part (`iPhone 13 back camera`) and plain `Back Camera` are left unchanged. Sony, Canon, Fuji and Sigma names are unchanged, apart from `/` (I2). Empty and whitespace-only values give nil. Unicode whitespace collapses. The reader already trims leading and trailing control characters (`ImageIOMetadataReader.trimmed`). Fewer collisions: different models and focal lengths stay distinct, and `back camera` and `back triple camera` for the same focal length collapse on purpose.
- **Key collisions.** 64-bit SHA-256 prefix (same as device groups), separate namespace `view/byLens/<key>`; no names go into logical paths.
- **Effect on other views.**
  - `ViewPlanner.enabledViews` only adds `.byLens` when the setting is on.
  - The planner only examines enabled views, so turning the view off keeps both the rows and the tree.
  - `needsEngineRecompute` and the `commitSettings` path queue the sweep that backfills when the view is turned on.
  - The rebuild path (`requestRebuild`, `ViewRebuildPreparation`, `restoreRemoved`) is view-agnostic. When By lens is off, `restoreRemoved` turns its `userRemoved` rows into `trashed` rows, and they are recreated if the view is turned on later. That is correct.
  - No `switch` over `ViewKind` or `ViewPath` in app code needed updating.
- **Settings decode.** `settingsSavedBeforeTheLensViewDecodeWithItOff` passes, and the other keys keep their values.
- **Recovery and remote inventory.** `ViewKind(rawValue: "byLens")` decodes. `RecoveryWriter` adopts the rows and applies `ViewHold` the same way as for other views; the provisional-category hold covers lens data that has not been read yet. Folder rows are restored with the names they have on Drive. Nothing like `device_group` is needed because the name comes from EXIF.
- **Estimate.** The SQL matches the rule: camera category, non-blank lens, and the same `deleted_at IS NULL` that the other view counts use. `TRIM` removes only spaces, but stored values are already trimmed.
- **Schema.** `shortcut.view` is free text; no migration is needed.

## Test gaps

- No test for case-variant folder stability (I1); that test would have caught I1.
- `AppQueries.viewCounts` lens count is untested, as the other counts are.

## Unresolved questions

1. I2: should folders read `f1.78`, `f_1.78`, or something else? This needs the owner, because the approved examples show `f/`.
2. M3: should placeholder lens values (`----`, `0.0 mm f/0.0`) count as "no lens"?

Counts: Critical 0 / Important 2 / Minor 4
Status: DONE_WITH_CONCERNS. I1 should be fixed before merge. I2 needs an owner decision before release, because changing the key afterwards moves every shortcut.
