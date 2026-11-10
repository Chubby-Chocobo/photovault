# Changelog

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
