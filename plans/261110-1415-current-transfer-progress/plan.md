---
status: completed
branch: feat/current-transfer-progress
---

# Current transfer progress on the status line

Owner request: show the name and progress of the file being synced on the status line, so a long upload or download does not look like a hang.

| Phase | Name | Status |
|---|---|---|
| 1 | Engine reporting: tracker, sinks in export, import read, Drive chunks, local copy | Completed |
| 2 | AppSupport text and selection, app wiring, tooltip | Completed |
| 3 | Docs: spec FR-60, README, mockup, architecture | Completed |

## Decisions

- One choke point for downloads and exports: `ExportControl.record` already sees every chunk of Photos, Dropbox, Drive and Mac-folder reads, so it gets an optional `TransferSink`. Uploads and copies carry the sink on `UploadRequest.progress` (default nil), so the `Destination` protocol keeps its shape.
- `TransferTracker` is in memory with a lock, no timers. Updates publish at most every 0.5 s (leading edge); begin and end always publish. Between publishes `current` stays fresh.
- The Drive upload reports per acknowledged chunk (8 MiB), not per socket write: the transport sends each chunk as one request, and changing it would touch retry semantics. A slow link shows steps of one chunk.
- The 1-second rule and the "+N file khác" count live in `TransferLineText` (AppSupport). Because a long chunk may publish nothing, the app keeps a 1 Hz clock only while transfers exist so the line appears after one second.
- The line replaces the summary subtitle only in the normal states (syncing, importing, backfilling, synced). Paused, decision, offline and disk states keep their own subtitle.
- Sidecar jobs are not tracked (tiny, no original filename). Header reads for classification are not tracked.
- Privacy: `TransferProgress.description` redacts names; names live in the app's memory and view only.
- The icon tooltip uses `.help` on the menu bar label; whether macOS shows it for a status item could not be checked without running the app.

- Account on the line: `TransferProgress.accountEmail` comes from `SourceConfig.account` (imports) and `DestinationRecord.accountEmail` (Drive uploads); copies, exports and Mac folders have none. E-mails are middle-truncated at 28 characters.
- Dropbox browsing account e-mail: stored in the Keychain as `dropbox-account-email` beside the token (written by `DropboxTokenAuthorizer.store`, removed with the token, included in the factory-reset cleanup). An older token has none: `refreshDropboxEmail` asks `users/get_current_account` once and stores it. If that fails the line says "signed in" without the e-mail.
- Settings line sits in the existing imports row of `SourcesTab` (4 added lines); the hotfix-touched `AppModel+CloudImports.swift` is not edited.

- Elapsed time (`m:ss`) joins the line after 10 s; the 1 Hz app clock makes it move between 8 MiB chunk acks. Rates are not shown: between acks they would be a stale step.
- Photos export with 0 bytes received reads "Đang tải … từ iCloud". The assumption (not verified on a device): `PHAssetResourceManager` delivers data only after an iCloud-only original is on this Mac, so no byte callback fires during the download. If bytes do stream during download, the line shows normal export progress, which is also correct.

- Publishing: only the list filling or emptying bypasses the 0.5 s throttle; begin and end of a file among others wait for it, so a big first sync does not send an update per file. A change held back by the throttle is flushed by one deferred task at the end of the window (never more than one pending), so a file that ended leaves the line within about 0.5 s even when nothing else reports.
- The launch orphan sweep skips `dropbox-account-email` like `dropbox-account`. The lazy e-mail fetch saves only while the same sign-in is in place (`DropboxEmailRefresh`).

## Unresolved

- Tooltip on the status item is unverified on a real menu bar.
