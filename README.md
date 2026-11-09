# PhotoVault

Personal macOS menu-bar app. It backs up the Photos library (originals and edits) to one Google Drive folder and to any number of local or NAS folders. It never deletes backup data and never changes the Photos library.

> **Status:** the engine, the core packages, the menu bar, onboarding and Settings are in the repo. The M0 spikes have not been run, so several defaults are unverified. See [docs/spikes/README.md](docs/spikes/README.md).

Other references: the full spec is [docs/requirements/photovault-spec-v1.md](docs/requirements/photovault-spec-v1.md) (copy of GitHub issue #1), decisions are in [docs/decisions/](docs/decisions/README.md), and the sidecar format is in [docs/sidecar-schema.md](docs/sidecar-schema.md).

## Requirements

- macOS 14 or later (`MACOSX_DEPLOYMENT_TARGET = 14.0`).
- Xcode 26 with Swift 6.1 or later (`swift-tools-version:6.1`).
- A Google account for Drive (a personal Gmail account works).
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
3. APIs & Services → OAuth consent screen:
   - User type **External**. Fill in the app name and your e-mail address.
   - Add the scopes `https://www.googleapis.com/auth/drive.file`, `openid` and `email`. `drive.file` gives access only to files the app creates.
   - Branding: home page `https://photovault.annh.dev`, privacy policy `https://photovault.annh.dev/privacy`, terms of service `https://photovault.annh.dev/terms`, authorized domain `annh.dev` (see [Website](#website)).
4. On the same screen, click **Publish app** so the status shows **In production**. In *Testing* mode, refresh tokens expire after 7 days, and the backups would stop each week.
5. When you sign in, Google shows an "unverified app" screen. This is expected for a personal app. Click **Advanced**, then continue to the app.
6. APIs & Services → Credentials → **Create credentials** → **OAuth client ID** → application type **Desktop app**. Copy the client ID and the client secret.
7. In the repo, copy the template and fill in the two values:

   ```sh
   cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig
   ```

   `Config/Secrets.xcconfig` is gitignored.

The build writes the two values into the app's `Info.plist` (`PVGoogleClientID`, `PVGoogleClientSecret`). The client secret of a Desktop client is not treated as confidential (see the note in `Sources/PhotoVaultDrive/OAuthClient.swift`). Do not reuse this OAuth client for other apps.

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

## Configuration

Settings is where you change these. Defaults come from `Sources/PhotoVaultCore/Models/Settings.swift` and match spec FR-05.

| Setting | Default | Notes |
|---|---|---|
| Videos, edited versions, every burst frame | on | Global ceiling. A destination can only narrow it. |
| Hidden album | off | Hidden photos are scanned, not uploaded. |
| Day-folder threshold N | 10 | A day with more than N camera photos gets its own folder. |
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
| Place names | on; language `vi`; home country `VN` | A separate setting: changing it renames day folders on destinations. See [privacy](#privacy). |
| Sidecars, JSON and XMP | on, on | Can also be set per destination. |
| Views: By device, By place, Favorites | on | Google Drive only. |
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

- The app has no server, no analytics and no crash reporter. It connects only to Google (sign-in, Drive) and to Apple's reverse geocoder (`CLGeocoder`).
- **Place names:** the geocoder receives the centre of a grid cell of about 1 km (0.01°), not your photo's coordinates. Deleted photos are never sent, and hidden photos are sent only when Hidden upload is on. You can turn place names off in Settings.
- **Sidecars contain location and album names.** The JSON sidecar holds the exact latitude and longitude (6 decimals), album names, the camera, and the place. Use per-destination rules to switch sidecars off for a destination you do not trust. The format is in [sidecar-schema.md](docs/sidecar-schema.md).
- **No client-side encryption.** Files in Drive and on the NAS are stored as plain files. Google encrypts data at rest on its side; the app adds no encryption of its own.
- **Hidden photos are not uploaded** by default.
- **Tokens** are stored only in the macOS Keychain on this Mac, in the data-protection keychain, which is not synced.
- **Permissions:** Photos (read), network, and the folders you pick. The app does not ask for Full Disk Access and does not read `Photos Library.photoslibrary` directly.

## Using the app

The menu bar shows the overall state, one line per destination, backfill progress, and the actions Sync now, Pause/Resume, Open Drive, Reveal NAS, recent activity, Settings, Log and Quit. The interface is described in [docs/design/README.md](docs/design/README.md), with interactive mockups in `docs/design/mockups/`.

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
- **Backfill is slow by design.** It runs at 20 GB per hour on power, and Photos downloads each original first (spec §8.5).

## Uninstall

1. In Settings, sign out of Google. This deletes the refresh token from the Keychain (service `com.annh.photovault.google`, account `refresh-token`) and revokes it at Google.
2. Turn off **Launch at login**, or remove PhotoVault under System Settings → General → Login Items.
3. Quit from the menu bar, then delete `/Applications/PhotoVault.app`.
4. Delete the app's data: `~/Library/Containers/com.annh.photovault`. It holds the database, staging files, database snapshots and logs.
5. Check [myaccount.google.com/permissions](https://myaccount.google.com/permissions). If PhotoVault is still listed, remove it.
6. Backup data is never deleted by the app, including during uninstall. Files in your Drive folder and on your NAS stay where they are. Delete them yourself if you want them gone. Removing a destination in the app deletes only the app's record of it.
