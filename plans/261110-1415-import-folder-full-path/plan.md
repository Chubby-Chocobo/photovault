# Import history shows where each import came from

Status: Completed. Owner request: two imports of folders both named "2024" look the same; show the full location.

## Phases

| Phase | Name | Status |
|---|---|---|
| 1 | Core: `SourceConfig.locationPaths/locationURL`, `ImportLocationPath`, `ImportLocation` (red-first tests) | Completed |
| 2 | Drive: parent-chain resolver (`pickedLocations`), never fails the import | Completed |
| 3 | Engine/AppSupport: snapshot field, texts | Completed |
| 4 | App: record at creation, row line, Finder/web links, popover tooltip | Completed |
| 5 | Docs: spec FR, README, mockup | Completed |

## Decisions

- One field `locationPaths: [String]?` for every kind (Mac and Drive store it; one element for a Mac folder), instead of a separate `locationPath`. Config is JSON and the fields are optional, so old rows decode and no migration is needed (tested).
- Dropbox stores nothing new: `remoteItems[0]` is already the `path_display` the folder browser returned ("" = whole account, shown as "/"). New and old rows use the same derivation.
- Drive also stores `locationURL` (folder link of the first pick; for a file, its parent folder) because the link needs an id the display string lacks.
- Drive walks at most 5 picks, 20 levels, 100 requests; any error returns nil and the import keeps its name only. Names "My Drive", "Shared with me", "Shared drive" are fixed English (they are written once at creation, not re-localised).
- Mac home is shown as "~" using the real home from `getpwuid`, not `NSHomeDirectory()` (that is the sandbox container).
- Older Mac rows: path derived from the bookmark when the row appears (off the main thread); nothing written back.
- Privacy: `SourceConfig` and `ImportLocation` have redacted `description`s, so default string dumps never include paths, bookmark or account.
- Spec: new FR-126 (FR-125 was taken). No import-row mockup exists in `docs/design/mockups`, so none changed.
- Drive walk also has a 10 s overall timeout so a slow network cannot hold the import back.
- Long paths: `ImportLocationShortener` keeps root and last folder, drops the middle as one "…", then middle-truncates the last name; the row tries budgets 200/60/45/32/22 characters with `ViewThatFits`. Full text: tooltip, copy button, click-for-popover. The popover card keeps the full path as a native tooltip (it wraps), not a shortened one.
