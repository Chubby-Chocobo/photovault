# Release 0.4.0: CHANGELOG notes (Setup and Upgrade)

Paste these sections into `CHANGELOG.md` at release time. Checked against HEAD of `release/0.4.0` (`10861e6`) plus the final polish branch (`fix/release-0.4.0-final-polish`) on 2026-11-10.

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

## Release steps for these notes

- Paste the two sections above into `CHANGELOG.md` with `git-flow.cjs changelog --write` on the release branch, or by hand on the release branch only (never on a feature branch).
- Set the 0.4.0 date in `docs/requirements/roadmap.md` (the header still says "đang phát triển").
- If `site/public/privacy.html` is deployed on a later day than 2026-11-10, bump its effective date.
