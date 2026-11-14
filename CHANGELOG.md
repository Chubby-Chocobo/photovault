# Changelog

## [0.8.0] - 2026-11-14

### Upgrade notes

- No database migration. 0.8.0 opens the same database as 0.7.x, and 0.7.x can still open it after 0.8.0 has.

### Performance

- PhotoVault uses much less memory. On the owner's Mac the idle footprint went from about 100 MB (0.7.1 after two days) to about 22 MB right after launch. With generated test files, the peak above start fell from about 20 MB to 6 MB for a 300 MiB backup or folder import, and from about 13 MB to 1.5 MB for listing a 10 000-file folder. Nothing the app does changed (#107, #108) (1b76ce4):
  - Drive uploads read each 8 MiB chunk straight from the staged file on the Mac's internal disk instead of copying it into memory. Staged files on other volumes are read as before.
  - Loops over Photos library objects and folder listings free memory as they go.
  - SQLite keeps smaller caches and releases them after each sync.
  - While idle the app no longer wakes every 10 seconds, the retry countdown runs only while the popup is open, and the Log window reads only the end of each log file.

## [0.7.2] - 2026-11-12

### Documentation

- The project is published under the MIT License (`LICENSE`), with a License section in the README. The app itself does not change (#94, #95) (e4698cc)

## [0.7.1] - 2026-11-11

### Bug fixes

- **app:** the menu bar popup fits its content again instead of the fixed 520 pt area from 0.7.0, which left a large gap under the destinations. Text that changes every second still keeps its one-line slot, and while the popup is open its height only grows, so a card that goes away doesn't pull the bottom rows up. Opening it again measures it fresh. Empty activity slots are hidden from VoiceOver, idle spinners no longer animate, and the height cap leaves room for the NAS folder list (#90, #92, #93) (b44c6e3)

## [0.7.0] - 2026-11-11

### Upgrade notes

- The database gains a sync history (migration `v8-transfer-history`). The migration only adds: one column on `upload_job` (`backfill_run_id`), the tables `transfer_event`, `backfill_run` and `integrity_check`, their indexes, and a trigger that records each upload outcome in the same statement that changes the job. Uploads that finished before 0.7.0 are seeded once as approximate entries, dated by the job's last change. Earlier backfill jobs go into one "before history" run. As with every earlier migration, 0.6.x refuses a database this version has opened.
- History is kept indefinitely. File names appear only in the History window and in a CSV you save yourself, never in logs, activity or notifications.

### Features

- A History window lists what was synced: continuous Photos sync, each backfill run, and each one-time import's files. It has search, filters (outcome, destination, capture date, deleted from Photos with the backup kept), a timeline, the last integrity check per file and destination, retry of failed files and CSV export (#82, #84) (b9a0da2)

### Bug fixes

- **app:** the menu bar popup keeps one size while files move. Each changing line has a fixed one-line slot, long file names are shortened in the middle so the extension stays visible, and the action rows at the bottom no longer shift (#88, #89) (2827a46)
- **drive:** the browser page after Google sign-in says why sign-in failed. For example, it tells you to tick the Google Drive permission box when it was left unticked. A slow sign-in that succeeds is no longer reported as failed in the browser (#85, #86) (8298ca6)

## [0.6.0] - 2026-11-11

### Upgrade notes

- Pause now also stops new downloads into staging. Before, an import kept downloading while paused until staging was full.

### Features

- **engine:** download the next import batch while the last one uploads, so an import from Google Drive or Dropbox to a cloud destination takes close to the longer of the download and the upload instead of their sum (#79) (591c1d1)

### Maintenance

- The import-cancel tests wait for real signals instead of a 10 s bound (#80).

## [0.5.1] - 2026-11-10

No user-facing changes.

### Maintenance

- Tests no longer depend on machine speed or on the random retry wait, so CI passes reliably on GitHub's macOS runners (#71, #74).
- Every fast-path check of an import cancel now has a test (#68).

## [0.5.0] - 2026-11-10

### Upgrade notes

- The database gains two empty columns on `import_item` (`fail_count`, `first_failed_at`; migration `v7-import-retry`), so the one-day give-up for an unreadable import file now holds across relaunches. As with every earlier migration, 0.4.x refuses a database this version has opened.
- If you downgrade to 0.4.x and press "Đăng nhập lại" on a Google Drive import there, that import's settings are saved again without the stored folder location. After upgrading again, that Drive row shows only the folder name. Mac folder imports find their path again from the bookmark, and Dropbox rows are not affected.
- A folder import that is still waiting for its turn is forgotten if the app quits before it starts; pick the folder again.
- After a database loss, recovery reads back each Drive sidecar once (one small download per photo) instead of rewriting them all.

### Features

- **import:** import from the Google Drive or Dropbox folder synced on this Mac (#49) (faf8ad5)
- **import:** show where each import came from, with long paths shortened by folder (#48) (5ee44b7)
- **app:** show the file being transferred, its progress and account on the status line (#47) (fec52d3)

### Bug fixes

- **import:** make Cancel stop an import within seconds (#67) (8429cdc)
- **engine:** do not write sidecars again after a database recovery (#58) (d583b6a)
- **app:** show every waiting import as a queued row and list the import queue on its own (#61) (a85aebf)
- **app:** keep Dropbox sign-out reachable and put the ellipsis last in import item titles (#63) (ebd85d1)
- **app:** show the file being transferred on the Backfill and import cards (#59) (878d0fa)
- **engine:** queue the day's current name when a folder rename fails for good (#57) (1277188)
- **app:** offer "trên máy này" and "qua trình duyệt" as separate import choices (#60) (1beeb03)
- **import:** keep the retry count and first failure time across relaunches (#51) (71c42a9)
- **app:** name the Settings tab Địa danh instead of Địa danh & riêng tư (#56) (5387767)

## [0.4.2] - 2026-11-10

### Bug fixes

- **app:** say why a Google sign-in failed instead of a temporary error (#46) (29b5dc9). A sign-in without the Google Drive permission now names the box to tick; a rejected account token points at the Mac's date and time. The log keeps the reason code, never an account detail or token.

## [0.4.1] - 2026-11-10

### Bug fixes

- **import:** ask Google Drive consent in two steps, drive.file then drive.readonly (#45) (872cc08). The Picker sign-in no longer fails with `Error 400: invalid_scope`: Google allows `drive.file` alone for the desktop Picker, so the import asks twice for the same account, first the Picker (`drive.file`), then "Step 2 of 2" to read the chosen folder (`drive.readonly`). Another account in step 2 is refused; only the read grant is kept. An import whose start waits for a busy sync now shows as a queued item ("Chờ đến lượt"), and launch removes leftover import sign-ins.

### Setup

- No setup change beyond 0.4.0's. Step 2 shows Google's "unverified app" screen because `drive.readonly` is a restricted scope (Advanced › continue).

## [0.4.0] - 2026-11-10

### Setup

- **Google Drive import needs one more scope.** In the Cloud Console › OAuth consent screen › Data access, add `https://www.googleapis.com/auth/drive.readonly` next to `drive.file`, `openid` and `email`, and enable the Google Picker API. Only the one-time Google Drive import asks for `drive.readonly`; the backup destination stays on `drive.file` and does not need a new sign-in. `drive.readonly` is a restricted scope: the app stays unverified and Google shows the "unverified app" screen (Advanced › continue). Google Workspace accounts may be blocked from it by their admin. See "Google Cloud setup" in the README and decision 0030.
- No other setup change. Dropbox keeps the same App key and permissions.

### Upgrade notes

- **Do not downgrade after 0.4.0.** This release adds a database migration (`v6-day-place`). 0.3.0 and earlier do not know the new column and would write sidecar changes into the wrong folder; 0.2.0 cannot read cloud import sources. From 0.4.0 on, the app refuses to open a database written by a newer build.
- **The first sync after the update re-checks every camera day that was named by place.** 0.3.0 left days with photos in several provinces unnamed; 0.4.0 splits them into one folder per province (the largest group keeps the day's folder). This can rename folders and move already backed-up files on Google Drive and on local or NAS destinations, in passes of up to 500 moves per destination; Drive writes are limited to about 5 per second. Emptied folders are not deleted. Photos deleted from Photos stay where they are. When a destination throttles the moves, they back off and are queued again instead of failing for good. See decision 0028.
- **The safety backup taken before the 0.4.0 migration is not a rollback.** Restoring it moves nothing back. Under 0.4.0 the app recovers its state from the destinations. Do not restore that backup under 0.3.0: 0.3.0 would upload the moved files again and write sidecars into the main day folder.
- **Backfill is shown only while it runs.** The menu bar popover shows backfill and imports only while they have work left. A finished backfill is recorded once, in Settings › Nguồn, in Recent activity and in one notification. A backfill that finished under 0.3.0 is marked at the first sync with no notification. Files that recovery after a database loss only matches at a destination are not announced as a backfill.
- **Google Drive imports made with 0.3.0 may have found no files.** They only had `drive.file`, which cannot read inside a picked folder. They are not repaired: import the folder again from Settings › Nguồn › Nhập ảnh… › Từ Google Drive….
- **Finished imports let go of their sign-in.** Once a Google Drive or Dropbox import is finished or cancelled and none of its files is still pending, uploading, deferred or missing at a destination, its sign-in is deleted from this Mac. This also applies to imports made with 0.3.0, at the first sync after the update. The permission stays in your Google or Dropbox account until you remove it there. Adding a destination later, or re-uploading a lost file, asks you to sign in again ("Đăng nhập lại").
- **By lens is off by default.** Turn it on in Settings › Sắp xếp (Organization); it adds one Drive shortcut per camera photo with a lens.

### Features

- **app:** show backfill only while it runs, like a one-time import (#40) (10861e6)
- **layout:** split a camera day into one folder per province (#35) (4819d84)
- **views:** By lens view (#30) (0c528f1)

### Bug fixes

- final 0.4.0 polish from the pre-release review (#41) (6d2540f)
- **engine:** back off throttled moves and queue failed moves again (#39) (806c1ad)
- **drive:** scan a long sign-in request once instead of on every read (#38) (3352a55)
- **import:** read the contents of a picked Google Drive folder (#34) (d45c4bc)

## [0.3.0] - 2026-11-10

### Setup

- Google Drive imports need the **Google Picker API** enabled in the existing Cloud project.
- Dropbox imports need a Dropbox app and its App key as `DROPBOX_APP_KEY` in `Config/Secrets.xcconfig`. Without the key, the Dropbox item stays disabled.
- See "Dropbox setup" and "Import from a folder › From Google Drive or Dropbox" in the README, and decision 0026.

### Features

- one-time import from a Google Drive or Dropbox folder (#25) (3898e9e)

### Bug fixes

- **views:** keep the place shortcut of a photo deleted from Photos (#26) (945efad)

## [0.2.0] - 2026-11-09

### Breaking changes

- Destinations now use one folder per day (`Camera Uploads/YYYY-MM-DD[ place]`) instead of `YYYY/MM/DD`. Existing backups are not migrated. 0.2.0 stops syncing a 0.1.0 database and asks for **Start over** (Settings › Advanced). Move the old Drive or NAS root to the Trash first and do not reuse it. See "Upgrading from 0.1.0" in the README and decision 0025.

### Features

- several sources and one-time import from a folder on this Mac (#22) (e365c4e)
- start over from onboarding with a factory reset (#20) (6e23493)
- fill recent activity and read the log in the app (#18) (b155ffd)
- organise destinations by day and fix place-name languages (#14) (5cb08da)
- show the interface in Vietnamese or English with a live switch (#13) (0036f39)
- **app:** open Settings when the running app is opened again (#10) (2ca2c23)
- **app:** add the PhotoVault app icon (#7) (7f3b518)
- **site:** add the landing page with privacy policy and terms (#6) (cbcd7e0)

### Bug fixes

- **engine:** root commands also stop for an old-layout database (6fc25c2)
- **app:** one phrasing for restoring state, clearer reset relaunch message (5720789)
- **app:** let the menu bar popover scroll so Settings and Quit stay reachable (7380e44)
- **app:** import notice posts once, failed folder pick says so, waiting reason shown (0e48090)
- **app:** do not offer to reuse a 0.1.0 backup folder (bf828ee)
- **engine:** do not recover from a root that holds the old folder layout (f94fef1)
- **app:** tell the owner an old-layout backup needs a fresh start (08ebed6)
- **engine:** stop syncing a database written with the old folder layout (c94f3d4)
- retry transient folder and id errors without costing an attempt (#19) (ad6bf6a)
- **app:** give the app a Keychain access group so sign-in can store its token (#8) (4d81e38)

## [0.1.0] - 2026-11-09

### Features

- build PhotoVault v0.1.0 menu bar backup app (#2) (451f1c3)

### Bug fixes

- address the full codebase audit of v0.1.0 (#3) (6d916b1)
