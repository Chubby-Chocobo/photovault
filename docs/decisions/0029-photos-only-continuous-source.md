# 0029 Photos is the only continuous source

- **Status:** Accepted
- **Date:** 2026-11-10
- **Spec refs:** §2 (item 9, non-goals), §8.1, §15 (amended); FR-110, FR-120
- **Review trigger:** the owner asks for a continuous Dropbox, OneDrive, Google Drive (another account), S3 or Flickr source; or the safety rules in [continuous-source-extension](../architecture/continuous-source-extension.md) are implemented and tested for one provider

## Context

Issue #17 asked for sources beyond Photos. Round 2 (v0.3.0) shipped one-time imports from Google Drive and Dropbox folders (decision 0026). A continuous Dropbox source was planned on branch `feat/17-dropbox-continuous`. Its audit found two critical risks: renaming, recreating or deleting the watched root could retire every asset of the source, and an asset could be retired while another live row still held its bytes. It also found eight important gaps, including a retry gap for failed files and a migration that could break a newer build. On 2026-11-10 the owner decided that the Photos library is the only continuous source for now, and that Dropbox and Google Drive folders stay one-time imports.

## Decision

- Photos is the only continuous source in 0.4.0 and later until a new decision says otherwise.
- No code for a continuous source is written. Settings › Nguồn › Nguồn liên tục lists Photos only.
- The mechanism for adding a continuous source is designed in [continuous-source-extension](../architecture/continuous-source-extension.md) and is not implemented. The plan and audit stay on `feat/17-dropbox-continuous` for resuming.
- Spec §2 and §15 say this. Spec §8.1 records the `x:` key for any future continuous source as a proposal, not a settled rule; it replaces the `s:<sourceId>/<itemId>` key of decision 0024 in that proposal only. Decision 0024 itself is not edited.

## Consequences

- Imports from Dropbox and Google Drive stay one-time. A file added to a watched Dropbox folder after its import is not backed up.
- No new schema, migration or Keychain grant for continuous sources in this release.
- Issue #17 stays open and on hold. Its roadmap entries are in [roadmap](../requirements/roadmap.md).
- Future continuous sources must meet the safety rules R1–R15 of the extension doc before they ship. That doc is the single provider guide.
- Numbering: 0028 is taken by the split-day decision (branch `feat/27-split-day-by-place`), and 0030 by the Drive import decision (`drive.readonly`, branch `fix/drive-import-reads-folder-contents`). This record keeps 0029 for the merge that lands it. Any later decision, including the continuous Dropbox decision in the paused plan, takes the next free number at its merge (0031 or later), and the index in `docs/decisions/README.md` is updated then.
