# PhotoVault

Personal macOS menu-bar app. It backs up the Photos library (originals and edits) to one Google Drive folder and to any number of local or NAS folders. It never deletes backup data and never changes the Photos library. Photos is the main, ongoing source; Settings › Nguồn (Sources) can also import a folder once: a folder on this Mac, or a folder on Google Drive or Dropbox. The imported files get the same folder layout, names and sidecars as Photos assets ([decision 0024](docs/decisions/0024-multiple-sources-and-folder-import.md), [decision 0026](docs/decisions/0026-cloud-folder-imports.md)).

> **Status:** the engine, the core packages, the menu bar, onboarding and Settings are in the repo. Of the M0 spikes, M0-1b and M0-5 ran on 2026-11-09 and M0-6 ran too (its 24-hour repeat is still due); M0-1, M0-2, M0-3 and M0-4 are pending an owner run, so several defaults are unverified. See [docs/spikes/README.md](docs/spikes/README.md).

## Upgrading from 0.1.0

Version 0.2.0 files photos in a new folder layout (one folder per day under `Camera Uploads`, `Screenshots` and `Saved`; see [Folder layout](#folder-layout)). Backup data is never deleted, and an old layout is not migrated, so an old backup is not converted: you start over with a new root folder.

If you already have a 0.1.0 backup:

1. Open 0.2.0. It finds the 0.1.0 database and stops syncing at once, without touching your Drive or NAS. The menu bar shows a red card, "Bản sao lưu này dùng bố cục thư mục cũ (0.1.0)" (this backup uses the old folder layout), and Settings › **Nâng cao** (Advanced) opens with the reset section at the top.
2. In Google Drive, and on the NAS if you use one, move the old PhotoVault root folder to the Trash. Do not reuse it: 0.2.0 refuses a folder with the old layout (the year folders `2026/11/…`), because adopting it would move every file or upload everything twice. Leaving it in place and creating a new root with another name also works.
3. In Settings › **Nâng cao** (Advanced) click **Đặt lại từ đầu…** (Start over…) and confirm. PhotoVault signs out of Google, deletes its own data on this Mac and reopens first-time setup. See [Start over](#start-over-factory-reset).
4. Set up again with a new root folder. The whole library is uploaded again into the new layout.

Why: [decision 0023](docs/decisions/0023-day-folders-and-place-name-rule.md) and [decision 0025](docs/decisions/0025-old-layout-block-and-reset.md).

**Do not downgrade after 0.4.0.** 0.4.0 adds a database migration and files a day's photos in several folders; 0.3.0 and earlier do not know the new column and would put sidecar changes in the wrong folder, and 0.2.0 cannot read cloud import sources. Builds from 0.4.0 on refuse to open a database written by a newer build.

Other references: the full spec is [docs/requirements/photovault-spec-v1.md](docs/requirements/photovault-spec-v1.md) (copy of GitHub issue #1), decisions are in [docs/decisions/](docs/decisions/README.md), and the sidecar format is in [docs/sidecar-schema.md](docs/sidecar-schema.md).

## Requirements

- macOS 14 or later (`MACOSX_DEPLOYMENT_TARGET = 14.0`).
- Xcode 26 with Swift 6.1 or later (`swift-tools-version:6.1`).
- A Google account for Drive (a personal Gmail account works).
- A Dropbox account and a Dropbox app, only if you use the Dropbox import (see [Dropbox setup](#dropbox-setup)).
- An Apple ID, for a free Personal Team (only needed to run the signed app).

## Build and test

```sh
swift build
swift test
```

SwiftPM fetches GRDB.swift 7.12.0. Tests use Swift Testing.

To build the app target without signing:

```sh
xcodebuild -project PhotoVault.xcodeproj -scheme PhotoVault -configuration Debug build \
  CODE_SIGNING_ALLOWED=NO -derivedDataPath build/DerivedData -skipPackagePluginValidation
```

An unsigned build is not sandboxed, so it refuses to start unless it is launched with `--dev-container`. In Xcode, enable that argument under Edit Scheme → Run → Arguments. The dev run keeps its state in `~/Library/Application Support/PhotoVault-dev/`, apart from the signed app's state ([decision 0009](docs/decisions/0009-sandbox-container.md)).

CI (`.github/workflows/ci.yml`) runs `swift build`, `swift test` and the unsigned app build on a macOS 15 runner.

## Google Cloud setup

Do this once, in your own Google account. The app cannot do it for you.

1. Go to [console.cloud.google.com](https://console.cloud.google.com) and create a project.
2. APIs & Services → Library → **Google Drive API** → Enable.
3. APIs & Services → Library → **Google Picker API** → Enable. It is used only for the one-time import from Google Drive. It needs no API key.
4. APIs & Services → OAuth consent screen:
   - User type **External**. Fill in the app name and your e-mail address.
   - Add the scopes `https://www.googleapis.com/auth/drive.file`, `https://www.googleapis.com/auth/drive.readonly`, `openid` and `email` (Data access). The Drive backup destination asks for `drive.file` only: access to files the app creates and files you pick in the Picker. The one-time Google Drive import asks for `drive.file` in the Picker step and, in a second, separate sign-in, for `drive.readonly`, to read inside the folders you pick (Google does not allow `drive.file` to be combined with another scope for the Picker, [decision 0030](docs/decisions/0030-drive-import-reads-folder-contents.md)). Both scopes stay on the consent screen. Google describes it as "See and download all your Google Drive files".
   - Branding: home page `https://photovault.annh.dev`, privacy policy `https://photovault.annh.dev/privacy`, terms of service `https://photovault.annh.dev/terms`, authorized domain `annh.dev` (see [Website](#website)).
5. On the same screen, click **Publish app** so the status shows **In production**. In *Testing* mode, refresh tokens expire after 7 days, and the backups would stop each week.
6. When you sign in, Google shows an "unverified app" screen. This is expected for a personal app (`drive.readonly` is a restricted scope and the app stays unverified). Click **Advanced**, then continue to the app.
7. APIs & Services → Credentials → **Create credentials** → **OAuth client ID** → application type **Desktop app**. Copy the client ID and the client secret.
8. In the repo, copy the template and fill in the two Google values:

   ```sh
   cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig
   ```

   `Config/Secrets.xcconfig` is gitignored.

The build writes the two values into the app's `Info.plist` (`PVGoogleClientID`, `PVGoogleClientSecret`). The client secret of a Desktop client is not treated as confidential (see the note in `Sources/PhotoVaultDrive/OAuthClient.swift`). Do not reuse this OAuth client for other apps.

## Dropbox setup

Needed only for the Dropbox import. Do this once, in your own Dropbox account.

1. Go to [dropbox.com/developers/apps](https://www.dropbox.com/developers/apps) and click **Create app**.
2. Choose **Scoped access** and the access type **Full Dropbox**. Full Dropbox is needed to reach a folder such as `/Camera Uploads`. The app only reads.
3. On the **Permissions** tab, tick `files.metadata.read`, `files.content.read` and `account_info.read`, then **Submit**. Do this before the first sign-in: Dropbox grants only the permissions that are enabled when you sign in.
4. On the **Settings** tab, under **OAuth 2** → **Redirect URIs**, add exactly `http://localhost:53682/oauth2/callback`, then **Add**.
5. To import from a Dropbox account other than the one that created the app, open the **Settings** tab and use **Enable additional users**. A Dropbox app in development status links only its creator's account until then.
6. Copy the **App key** (not the app secret) into `Config/Secrets.xcconfig`, which you copied from `Config/Secrets.xcconfig.example`:

   ```
   DROPBOX_APP_KEY = your-app-key
   ```

Leave `DROPBOX_APP_KEY` empty (as the template does) to build without Dropbox: the Dropbox item in Settings is then disabled and shows a hint. The app uses PKCE, so no secret is needed.

Dropbox tokens live in the same Keychain service as the Google token (`com.annh.photovault.google`), under the account names `dropbox-account` and `import-<id>`.

## Signing

The app needs a stable signature. macOS ties its Photos and folder permissions (TCC) to the signature and the bundle ID `com.annh.photovault`. Each change of signature asks for those permissions again.

1. In Xcode, open Settings → Accounts and add your Apple ID. A paid Apple Developer account works best (its certificates and profiles last a year); without one, Xcode creates a free Personal Team. Use your own team, not an employer's. Then click Manage Certificates → + → Apple Development.
2. Copy the template and set your Team ID (from the same Accounts pane):

   ```sh
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```

   Set `DEVELOPMENT_TEAM` in the file. It is gitignored.
3. In the target's Signing & Capabilities, keep **Automatic** signing with that team. Do **not** choose **Sign to Run Locally**. That is ad-hoc signing, and every build loses the permissions.
4. The app stores the Google token in the data-protection Keychain, which needs a Keychain access group (`Config/PhotoVault.entitlements`). That entitlement comes with a provisioning profile, and the profile must list this Mac. Xcode registers the Mac and creates the profile on the first build; from the command line:

   ```sh
   xcodebuild -project PhotoVault.xcodeproj -scheme PhotoVault -configuration Release \
     -derivedDataPath build/DerivedData -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
   ```

5. Build the app, then copy `PhotoVault.app` to `/Applications` and run it from there. Repeat the copy after each build. In Xcode, Product → Show Build Folder in Finder shows the built app.

Personal Team profiles expire. If Xcode reports the profile as expired, sign again and copy the app again. [M0-4](docs/spikes/m0-4-signing-sandbox-and-filesystems.md) measures how long a profile lasts.

## NAS and local folders

1. Mount the SMB share yourself, for example in Finder with Go → Connect to Server. PhotoVault never mounts network shares.
2. In Settings, open the **Đích** (Destinations) tab and add a folder. The folder picker stores a security-scoped bookmark for it.
3. Press **Test connection**. The app writes, reads and deletes `.photovault-test` in the folder.
4. Choose the sync scope (`full`, `since` a date, or `newOnly`) and the content rules for this destination.
5. The app writes `.photovault/destination.json` into the folder. If a folder already has that file, the app asks whether to reuse it and recover the backup ([FR-74](docs/requirements/photovault-spec-v1.md), [FR-51](docs/requirements/photovault-spec-v1.md)).
6. When the share is unmounted, the destination shows as unavailable and is checked again every 5 minutes. Files are not held in staging for it; they are exported again when it returns, at the backfill rate.

## Folder layout

Every destination gets the same tree under its root (default name `PhotoVault`). The views (By device, By place, Favorites, and By lens when it is turned on) exist on Drive only and hold shortcuts, not copies. A phone lens name is shortened, for example `iPhone 15 Pro 6.86mm f1.78` ([FR-107](docs/requirements/photovault-spec-v1.md)).

```
PhotoVault/
├── Camera Uploads/
│   ├── 2026-04-26 Hà Nội/           one folder per day; the place is added 6 hours after the day ends
│   ├── 2026-04-27 Hà Nội/           a day with photos in two provinces gets one folder per province
│   ├── 2026-04-27 Ninh Bình/
│   ├── 2026-10-02 Kyoto (京都市), Japan/
│   └── Unknown date/
├── Screenshots/2026-04-26/
├── Saved/2026-04-26/                 photos saved from chat apps or without camera EXIF
├── By device/Sony A7 IV/2026-04-26/
├── By place/Vietnam/Lâm Đồng/2026-04-26/
├── By lens/FE 24-70mm F2.8 GM/2026-04-26/   off by default
└── Favorites/2026-04-26/
```

A day with photos in several provinces is split once it ended at least 6 hours ago: the largest group keeps the day's folder, the others get their own, and files already backed up are moved ([decision 0028](docs/decisions/0028-split-day-by-place.md)). Photos you delete in Photos are not moved, so they stay in the folder they were in. Emptied folders stay. Running "Làm mới địa danh" can regroup days and move files again.

Files are named `YYYY-MM-DD HH.mm.ss_<original name>`; an asset's original, RAW, Live Photo video, edited version and sidecars sit together. Updating from a build with the old `YYYY/MM` layout means starting over: see [Upgrading from 0.1.0](#upgrading-from-010) and [decision 0023](docs/decisions/0023-day-folders-and-place-name-rule.md).

## Configuration

Settings is where you change these. Defaults come from `Sources/PhotoVaultCore/Models/Settings.swift` and match spec FR-05.

| Setting | Default | Notes |
|---|---|---|
| Videos, edited versions, every burst frame | on | Global ceiling. A destination can only narrow it. |
| Hidden album | off | Hidden photos are scanned, not uploaded. |
| Backfill and re-export rate | 20 GB per hour | |
| Backfill only on power | on | |
| Uploads only on power | off | |
| Pause on expensive network | on | |
| Free-space watermarks, low / critical | 15 / 5 GB | |
| Staging soft limit | 4 GB | |
| Launch at login | on | |
| Chat-app album names | WhatsApp, Zalo, Messenger, Telegram, Viber, LINE, Signal, Instagram, Facebook, Threads, X, TikTok | Exact name match, case-insensitive. |
| Photos without camera EXIF go to Saved | on | See [known limits](#known-limits). |
| Interface language | Tiếng Việt | Settings → General: System, Tiếng Việt or English; switches at once. Folder names on destinations never change with it. |
| Place names | on; home country `VN` | Country in English; places in Vietnam in Vietnamese without the province prefix ("Hà Nội"); abroad English with the native name ("Kyoto (京都市)"). See [privacy](#privacy). |
| Sidecars, JSON and XMP | on, on | Can also be set per destination. |
| Views: By device, By place, Favorites | on | Google Drive only. |
| View: By lens | off | Google Drive only. Groups camera photos by the lens in EXIF; phone names are shortened ("iPhone 15 Pro 6.86mm f1.78"); placeholder values such as "0.0 mm f/0.0" are ignored. |
| Integrity check | every 7 days | |

Sync modes:

- `full`: everything in the library.
- `since(date)`: the photos of the given day onward, plus anything added after the baseline.
- `newOnly`: only what enters the library after you add the destination.

The archive timezone is fixed when you onboard. Changing the Mac's timezone later does not move files (spec §8.6).

## Website

`site/` holds the public landing page with the privacy policy and terms of service that the Google OAuth consent screen links to. It is static HTML served by Cloudflare Workers static assets at [photovault.annh.dev](https://photovault.annh.dev); `annh.dev` uses Cloudflare DNS.

```sh
cd site
npx wrangler dev      # preview on localhost
npx wrangler deploy   # publish (needs `npx wrangler login` once)
```

Keep `privacy.html` true to what the app does: when the app starts using new Google scopes, new services or new data, update the policy and its effective date in the same change.

## Privacy

- The app has no server, no analytics and no crash reporter. It connects only to Google (sign-in, Drive, and the Drive Picker), to Dropbox (only if you use the Dropbox import) and to Apple's reverse geocoder (`CLGeocoder`).
- **Place names:** the geocoder receives the centre of a grid cell of about 1 km (0.01°), not your photo's coordinates. Deleted photos are never sent, and hidden photos are sent only when Hidden upload is on. You can turn place names off in Settings.
- **Sidecars contain location and album names.** The JSON sidecar holds the exact latitude and longitude (6 decimals), album names, the camera, and the place. Use per-destination rules to switch sidecars off for a destination you do not trust. The format is in [sidecar-schema.md](docs/sidecar-schema.md).
- **No client-side encryption.** Files in Drive and on the NAS are stored as plain files. Google encrypts data at rest on its side; the app adds no encryption of its own.
- **Hidden photos are not uploaded** by default.
- **Tokens** are stored only in the macOS Keychain on this Mac, in the data-protection keychain, which is not synced. That includes the Dropbox account and one token per Drive or Dropbox import.
- **Dropbox and Google Drive imports** read only what you choose: the folder you pick in Dropbox, or the files and folders you pick in Google's Picker (the import asks for `drive.file` in the Picker, then `drive.readonly` in a second sign-in; the backup destination stays on `drive.file`). Nothing is written back to either service. An import's sign-in is deleted from the Keychain once the import is finished or cancelled and no file of it is still waiting to upload.
- **Permissions:** Photos (read), network, and the folders you pick. Dropbox access is read-only. The app does not ask for Full Disk Access and does not read `Photos Library.photoslibrary` directly.

## Using the app

The menu bar shows the overall state, one line per destination, backfill progress while the backfill runs, the card of a folder import that is running (progress, Cancel; see [Import from a folder](#import-from-a-folder)), and the actions Sync now, Pause/Resume, Open Drive, Reveal NAS, recent activity, Settings, View log and Quit. View log opens an in-app log window (level filter, search, copy, reveal folder); the log rotates over 5 files of 5 MB, so it never takes more than 25 MB. While a file moves, the line under the title names it and shows its progress, for example `Uploading IMG_1234.MOV to Google Drive · 1.2 / 2.6 GB (46%)` (with the Dropbox or Google Drive account in brackets for cloud transfers, and `+2 more files` when several run at once), so a large video is not mistaken for a hang; it covers exports from Photos, downloads from Dropbox and Google Drive, uploads and copies to folders, and shows after the file has run for a second. Settings › Sources shows which Dropbox account is signed in (`Dropbox: signed in as …`). File names and e-mails appear there and in the icon's tooltip only, never in logs, Recent activity or notifications. Backfill is a one-time job: when it finishes, its card leaves the menu bar and the end is kept as one Recent activity row, one notification, and a line under Photos in Settings › Sources. The interface is described in [docs/design/README.md](docs/design/README.md), with interactive mockups in `docs/design/mockups/`.

If a crowded menu bar hides the icon, open PhotoVault again (Spotlight, Finder or Launchpad): the running app shows Settings, or onboarding if it is not finished. On macOS 26, System Settings → Menu Bar chooses which apps keep an icon.

## Known limits

- **`saved` is a heuristic.** A photo with no camera make or model goes to `saved` (FR-20), so a scan or a photo that looks like a screenshot can land in `Saved`. Videos never use that rule, so drone footage stays in `camera`. Rules run in order: screenshot subtype, chat-app album, missing camera EXIF, otherwise `camera`.
- **Captions and keywords** are written only on macOS 27 or later, once the API is available. The current SDK does not have it, so sidecars say `"extendedMetadata": "unavailable"`. There is no title field.
- **No People or Memories.** They are not exported.
- **Old edited versions on Drive may disappear after about 30 days.** The app does not set `keepRevisionForever`. The duration is [VERIFY] in [M0-3](docs/spikes/m0-3-google-drive-behaviour.md).
- **NAS offline.** Nothing waits in staging for an offline destination. Its files are exported again when it returns, at the backfill rate. If a NAS stays offline for more than 7 days, you get a notification.
- **SMB checksum is best-effort.** The read-back after a write is a check, not a guarantee. The client cannot detect symbolic links created on the server.
- **Other programs can race the app.** On a filesystem without an atomic no-overwrite rename, another process could take a name between the app's check and its rename (FR-73). The app protects only against its own writes.
- **Lightroom and `.xmp`.** Lightroom reads an external `.xmp` only for proprietary RAW formats, and it can write into an existing `.xmp`.
- **digiKam** looks for `file.ext.xmp`. The app writes `<stem>.xmp`, so digiKam does not find it by default.
- **RAW and JPEG share one sidecar pair** (`<stem>.json` and `<stem>.xmp`).
- **Drive views add shortcuts.** Shortcuts count toward My Drive's item limit (the limit is [VERIFY] in M0-3). The app trashes only shortcuts it created; backup files are never touched.
- **Drive imports from 0.3.0 may be empty.** Those imports only had `drive.file` and could not read inside a picked folder. Import the folder again ([decision 0030](docs/decisions/0030-drive-import-reads-folder-contents.md)).
- **Nested folders under `drive.readonly` are not yet confirmed on a real account.** The Picker sign-in with the loopback redirect was confirmed by the 0.3.0 live run ([decision 0026](docs/decisions/0026-cloud-folder-imports.md)). Listing a picked folder and its subfolders is what the owner is testing now ([decision 0030](docs/decisions/0030-drive-import-reads-folder-contents.md)).
- **Cloud imports download each file twice:** once to read its date and hash, and once for the backup. A large Drive or Dropbox import uses twice the download traffic.
- **Imports use file metadata.** Screenshots are recognised by the EXIF marker iOS and macOS write; screen recordings and screenshots from other tools go to `Camera Uploads`. A Live Photo pair is joined only when both files carry Apple's content identifier.
- **Backfill is slow by design.** It runs at 20 GB per hour on power, and Photos downloads each original first (spec §8.5).

## Import from a folder

Settings › **Nguồn** (Sources) › **Nhập ảnh…** (Import photos…) › **Từ thư mục trên Mac…** (From a folder on this Mac…) picks a folder. PhotoVault reads it recursively, groups RAW+JPEG and Live Photo pairs, reads the dates and places inside the files, skips what is already backed up, and then backs the rest up like any other photo. The folder is only read: nothing in it is changed or deleted. Progress shows in Settings and in the menu bar; **Huỷ** (Cancel) stops a job (files already uploaded stay), and a notification and one line in Recent activity report the result.

- **Each import shows where it came from.** Under the folder name, Settings › Nguồn shows the location: the full path of a Mac folder (your home folder as `~`), the Dropbox path, or the path of each Google Drive pick from My Drive (first pick plus "+N more"). A long path is shortened by whole folders (`My Drive/…/Trips/2024`, keeping the root and the last folder); hover, or click the line, for the full text, or use the copy button. Mac folders get **Hiện trong Finder** (Show in Finder) while the folder can still be found, Dropbox and Drive imports get **Mở trên web** (Open on the web); the menu bar card shows it as a tooltip. Imports made before 0.5.0 show it when it can be found without the network (a Mac folder through its bookmark, Dropbox from its saved folder); older Drive imports show the name only. Paths stay on this Mac and are never logged.
- **Photos access is still required.** An import runs in the same cycle as Photos, so it waits until setup is done and Photos is allowed.
- **Photos is the only continuous source.** Google Drive and Dropbox folders can be imported once, as described below; more continuous sources are planned, see [the roadmap](docs/requirements/roadmap.md) and [the extension design](docs/architecture/continuous-source-extension.md).
- **Keep the folder and its disk connected until the job completes.** An unplugged disk pauses that job only and it continues when the disk is back.
- **Duplicates are matched by content, or by capture second + name + size.** A photo that is already in Photos or already exported is not uploaded twice. A photo added to Photos after it was imported is uploaded again.
- **Files that only had a file date** (no EXIF or QuickTime date) use the earlier of the file's creation and modification dates for the day folder.

### From Google Drive or Dropbox

An import you have just picked is listed in Settings › Nguồn › Hàng đợi nhập ("Import queue") as waiting for its turn until the running sync reaches a safe point. A pick that is still waiting is forgotten if the app quits first (nothing is stored for it yet): pick the folder again.

Settings › **Nguồn** › **Nhập ảnh…** › **Từ Google Drive…** or **Từ Dropbox…** starts the import. The row and the menu bar card show the account email.

- **Preferred: the desktop app.** If **Google Drive for desktop** (or the **Dropbox** app) is installed, the **Nhập ảnh…** menu lists **Google Drive trên máy này…** (or **Dropbox trên máy này…**), which opens a folder chooser at `~/Library/CloudStorage` ("Chọn thư mục Google Drive (đồng bộ trên máy này)"). Choose the account folder (`GoogleDrive-<email>`) and then "My Drive" or a subfolder; Dropbox's folder is `Dropbox`. The import is then a normal Mac-folder import: no sign-in, no Google "chưa xác minh" screen, subfolders included. The row reads "Google Drive (trên máy này) · <email>" or "Dropbox (trên máy này)". When this build also has the Google client ID (or the Dropbox key), a separate item **Google Drive qua trình duyệt…** (**Dropbox qua trình duyệt…**) opens the browser flow below, for an account that is not synced on this Mac. With only one way available the menu shows a single **Từ Google Drive…** / **Từ Dropbox…** item for it ([decision 0031](docs/decisions/0031-import-from-synced-cloud-folder.md)).
- **Online-only files** (the desktop app keeps them in the cloud) are downloaded when the import reads them, so you need enough free space; a file whose download times out, is cancelled or fails because the Mac is offline is tried again later with the same back-off as a Google Drive or Dropbox read, and the import waits with "chờ chỗ trống" when the disk is too full to download the next file. Keep the desktop app running and signed in during the import.
- Without the desktop app, the browser flows below are used.

- **Google Drive (browser):** a sheet first warns that Google will show "chưa xác minh" (not verified) because the app uses the Drive read permission, that this is your own app (choose Advanced › Go to PhotoVault), and that installing Google Drive for desktop avoids it; **Tiếp tục** / **Huỷ**. It also explains what to pick. The browser then opens Google's Picker. Sign in with the Google account that holds the photos; it can differ from your backup account. Pick photos, videos and/or folders. Google then opens a second page ("Step 2 of 2"): choose the same account and allow "see and download all your Google Drive files" (read only). Both pages show the unverified-app warning for a personal app. The app reads only what you pick and everything below picked folders, subfolders included.
  - When the import is finished or cancelled and no file of it is still waiting to upload, the app deletes this sign-in from this Mac. The permission itself stays in your Google account until you remove it at [myaccount.google.com/permissions](https://myaccount.google.com/permissions). Adding a backup destination later, or uploading a file again after the destination lost it, asks you to sign in again ("Đăng nhập lại").
  - Keep "See and download all your Google Drive files" ticked on the second page, or the app refuses the sign-in. Choosing a different account on the second page is refused too.
  - Google Workspace (school or work) accounts may not be able to use the import: an admin can block restricted scopes. Personal accounts are what this was tested for.
  - If the import finds no photos or videos, it says so (in Settings, in the notification and in Recent activity) and, in the Settings row for Google Drive, tells you to import again (Import photos… › From Google Drive…).
- **Dropbox:** sign in once in the browser, then choose a folder in PhotoVault's folder browser, or the whole Dropbox. Needs the App key ([Dropbox setup](#dropbox-setup)).
- **Cần đăng nhập lại** (sign in again): Google or Dropbox revoked the access, or the token is missing. An open import shows this and waits; so does a finished import whose files are still needed for a backup. Use the sign-in action on that import to continue. Sign in with the same account the import reads from: another account is refused with a notice and changes nothing. For Google, the new pick is added to the old one.
- **Signing out of the Google backup destination** also revokes the app's access for that Google account, so imports from the same account then wait and show "Cần đăng nhập lại". An import from another Google account keeps its sign-in on this Mac until the import is finished or cancelled and no file of it is still waiting to upload; the app then deletes that sign-in from this Mac. The Google permission itself stays in the account until you remove the app's access at [myaccount.google.com/permissions](https://myaccount.google.com/permissions). Start over deletes all the tokens on this Mac.
- **Dropbox** imports follow the same rule: the app deletes an import's sign-in from this Mac once the import is finished or cancelled and no file of it is still waiting to upload. The Dropbox account used by the folder browser keeps its sign-in until you sign out of Dropbox or use Start over. Its state is on the menu: while signed in, **Dropbox qua trình duyệt…** shows the account e-mail and the next item is **Đăng xuất Dropbox (<e-mail>)**; while signed out, the item's help says it will open the browser to sign in. The permission stays in your Dropbox account until you remove the app at [dropbox.com/account/connected_apps](https://www.dropbox.com/account/connected_apps).
- **Google's limit:** one Google account can hold 100 refresh tokens per OAuth client, and each Picker import creates one. Each "Đăng nhập lại" creates one too. After about 100 of them for the same account, Google drops the oldest, which may be the backup sign-in or an older import's grant; that one shows "Cần đăng nhập lại", and signing in again fixes it.
- **A file that cannot be read now** (dropped connection, throttling, not enough free disk space) waits and is tried again while the rest of the import goes on: first after 30 seconds, then after twice as long each time, up to an hour. Files that never failed are read first, so a few stubborn files never hold the rest back. A group of files (a photo and its video, for example) is given up as a whole when it has failed at least 10 times over at least 24 hours while Google or Dropbox was answering; it is then counted under "lỗi" so the import can finish, and importing the folder again retries it. If only the downloads fail for more than a day while the service still answers other requests, files can be counted under "lỗi" too; import the folder again then.
- Read-only: nothing in Drive or Dropbox is changed or deleted.

## Start over (factory reset)

Settings → **Nâng cao** (Advanced) → **Đặt lại từ đầu…** (Start over…) returns PhotoVault to first-time setup.
1. Before resetting, move the old backup folder on Drive (and on the NAS, if you use one) to the Trash yourself. The app never deletes backup data. If the old folder is still there and was written by 0.2.0 or later (the current layout), onboarding offers to reuse it; a folder from 0.1.0 is never offered (see [Upgrading from 0.1.0](#upgrading-from-010)).
2. On confirm, PhotoVault signs out of Google and relaunches. The refresh token is removed from the Keychain, and revoked at Google when Google can be reached. Every Drive or Dropbox token (the Dropbox account and one per import) is found by listing the Keychain and removed, whether or not the import still exists in the database.
3. Before opening anything, the new process deletes the database, staging files, database snapshots, logs and the notification history.
4. Two things are kept: the interface language, and `drive-daily-cap.json`. Google counts the 750 GB a day per account, not per database. If you then sign in with a different Google account, it starts from the old account's count for the rest of that 24 hours.
5. Onboarding then creates a new root and syncs into it. If the reset is cut short, for example by a crash, it finishes at the next launch.

## Uninstall

1. In Settings, sign out of Google. This deletes the refresh token from the Keychain (service `com.annh.photovault.google`, account `refresh-token`) and revokes it at Google.
2. Turn off **Launch at login**, or remove PhotoVault under System Settings → General → Login Items.
3. Quit from the menu bar, then delete `/Applications/PhotoVault.app`.
4. Delete the app's data: `~/Library/Containers/com.annh.photovault`. It holds the database, staging files, database snapshots and logs.
5. Check [myaccount.google.com/permissions](https://myaccount.google.com/permissions). If PhotoVault is still listed, remove it.
6. Backup data is never deleted by the app, including during uninstall. Files in your Drive folder and on your NAS stay where they are. Delete them yourself if you want them gone. Removing a destination in the app deletes only the app's record of it.
