# Import from the Google Drive / Dropbox folder synced to this Mac

Status: implemented on feat/import-from-synced-cloud-folder (not pushed).

| Phase | Name | Status |
|---|---|---|
| 1 | Detection, label, config field, text (tested with fakes) | Completed |
| 2 | Panel, menu wiring, warning sheet | Completed |
| 3 | ADR 0031, README, spec | Completed |

## Decisions

- Detection by `NSWorkspace` bundle id; the sandbox refuses to list `~/Library/CloudStorage` (verified with a sandboxed ad-hoc bundle), so a listing only refines the start folder. No entitlement added.
- Provider and account come from the picked path, not the menu entry, so a plain "folder on this Mac" pick inside a synced folder is labelled too.
- `syncedProvider` stored as optional text with a typed accessor, so an unknown future value still decodes.
- Warning sheet: the existing explainer sheet shown each time; no "do not ask again" (simplest).
- Dataless files: plain `open`/`read` already triggers the download; read errors are item-level and retried. No change to the local source; disk guard unchanged.
- Bookmark refresh callback now preserves the rest of the config.
