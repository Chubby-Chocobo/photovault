# 0027 By lens view

- **Status:** Accepted
- **Spec refs:** FR-100, FR-103, new FR-107
- **Review trigger:** the owner wants to rename or merge lens folders, or lens folders turn out too numerous or noisy

## Context

On 2026-11-10 (issue #24) the owner asked for a Drive view that groups camera photos by lens. EXIF `LensModel` is already stored per asset. Phones write long strings such as `iPhone 15 Pro back triple camera 6.86mm f/1.78` (Pixel uses the same form).

## Decision

- **Path:** `By lens/<lens name>/<YYYY-MM-DD>/`, logical path `view/byLens/<key>/<day>`.
- **Members:** `camera` assets with a non-empty lens model; no Unknown folder; a photo deleted from Photos keeps its shortcut, like the other views.
- **Name:** the EXIF string with whitespace collapsed; phone strings (iPhone, Pixel) of the form `<model> back <…> camera <rest>` become `<model> <rest>`, `<model> front <…> camera <rest>` become `<model> front <rest>`; apertures `f/N` are written `fN` (`iPhone 15 Pro 6.86mm f1.78`, owner decision, so a folder name never needs `/` replaced); other lenses unchanged. Placeholder values (only punctuation such as `----`, or `0.0 mm f/0.0`) are not lenses and get no folder. Sanitised like other folder names.
- **Key:** hash of the sanitised, NFC, lower-cased folder name, so variants collapse and two groups never share a folder name. The folder keeps the name it was created with; the app never renames a lens folder, including when shortcuts are created or moved into it.
- **Setting:** `viewByLensEnabled`, off by default. Settings saved by older releases lack the key and read as off (the settings store merges stored keys over defaults). Turning it on backfills from the database; turning it off leaves the tree as it is; "Dựng lại view" covers it (FR-103).
- **Schema:** no migration; `shortcut.view` is free text.

## Alternatives

- On by default: an update would create one shortcut per photo with a lens, thousands on My Drive.
- Raw EXIF names: long and noisy for iPhones.
- A lens-name table like `device-names.json`: needs upkeep for every lens; deferred until a rename feature exists.
- An Unknown folder: noise, and By device has none.

## Consequences

- Items on My Drive grow by one shortcut per lens-bearing camera photo when enabled; the Settings estimate includes it.
- Two spellings that differ only in case share a folder named after whichever came first.
- Rename and merge of lens groups are not available.
- Changing the name rule in a later release gives affected lenses new keys: their shortcuts move to new folders and the old folders stay on Drive, empty.
- No downgrade: a release without this view cannot read `shortcut` rows whose view is `byLens`.
