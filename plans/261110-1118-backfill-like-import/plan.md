# Backfill leaves the popover when it is done

Status: Completed. Owner request: backfill is a one-time job; the menu-bar popover only shows live information, so a finished backfill must not stay there. Treat it like a one-time import.

| Phase | Name | Status |
|---|---|---|
| 1 | Engine: completion detection, kv marker, activity row, snapshot field | Completed |
| 2 | AppSupport texts, notification, Settings line | Completed |
| 3 | Views, docs, mockup | Completed |

## Decisions

- Finished means: no backfill job open (pending, uploading, deferred, missingRemote), at least one backfill asset, and the cycle drained with no provisional asset waiting. Same predicate as the popover (`done == total`); cancelled and skipped jobs do not hold it.
- Detection runs at the end of a drained cycle, in the same transaction as its kv marker and its one activity row. kv keys: `backfill.completed_jobs` (finished backfill jobs at the last completion), `backfill.completed_at`, `backfill.completed_assets`, `backfill.completed_bytes`, `backfill.notify_pending`. A completion fires only when finished backfill jobs exceed `completed_jobs`, so a relaunch or later cycle never repeats it, and a new backfill (destination added later) fires again.
- Notification: the engine only sets `notify_pending`; the app posts it (when the system allows notifications) and then acknowledges it. A crash between post and acknowledge repeats it once with the same notification identifier, which replaces the first banner; nothing is lost. If notifications are not authorised it is acknowledged without posting.
- Upgrade: at the first cycle of a launch, when `completed_jobs` is missing and no backfill job is open but some are done, the engine records a silent completion (no activity row, no notification) timed at the newest finished backfill job, else without a time.
- The old per-destination row "Đã sao lưu xong ảnh cũ" is replaced by the single overall row, so the activity list holds one backfill row.
- Size is the sum of the sizes of finished backfill jobs (a photo uploaded to two destinations counts twice, like the "uploaded" total).
- Settings › Nguồn Photos row: "Đang backfill: x / y" while running, "Backfill: xong lúc <date> · N ảnh" after.
- Owner decision: one rule for every one-time job (backfill and imports from a Mac folder, Google Drive, Dropbox). The popover card is shown while any work remains, reading or only uploading, and hidden once finished. `PopoverJobVisibility` (AppSupport) holds the rule; the backfill card and `ImportProgressText.running` both use it. An import whose files are all read but whose uploads still run keeps status `importing` (`finishWhenDone` closes it only when no upload is pending or uploading), so it stays visible.
