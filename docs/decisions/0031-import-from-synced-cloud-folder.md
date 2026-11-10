# 0031 Import from the Google Drive or Dropbox folder synced to this Mac

- **Status:** Accepted
- **Spec refs:** FR-119 (amended), FR-120 (amended), FR-111; builds on [0026](0026-cloud-folder-imports.md) and [0030](0030-drive-import-reads-folder-contents.md)
- **Review trigger:** Google verifies the app for `drive.readonly`, Apple changes how File Provider folders are read, or the sandbox starts to allow listing `~/Library/CloudStorage`

## Context

The Google Drive import needs `drive.readonly` (0030), a restricted scope. The app is not verified, so Google shows "Google hasn't verified this app" on the second consent. Verification of a restricted scope takes weeks, involves a security assessment, and may be refused because a narrower scope (`drive.file`) exists. The owner has Google Drive for desktop and the Dropbox app installed. Both keep the account as a folder on the Mac (`~/Library/CloudStorage/GoogleDrive-<email>/` with "My Drive" and "Shared drives", `~/Library/CloudStorage/Dropbox*`, legacy `~/Dropbox`).

## Decision

- **When the provider's desktop app is installed, "Từ Google Drive…" and "Từ Dropbox…" use its synced folder.** The app opens an `NSOpenPanel` at the synced folder and runs the existing Mac-folder import on the pick (read-only security-scoped bookmark, recursive, same engine). No OAuth, no consent screen, no token in the Keychain.
- **The web flows stay as the fallback.** Without the desktop app the menu entry opens the same flows as before (Picker + `drive.readonly`; Dropbox OAuth). With the app installed, the panel has a "Dùng trình duyệt thay thế" button that opens the web flow instead.
- **The sandbox decides how to detect.** Verified with an ad-hoc signed app bundle carrying `app-sandbox` and `files.user-selected.read-write`: `contentsOfDirectory` on `~/Library/CloudStorage` fails with "Operation not permitted", while `NSWorkspace.urlForApplication(withBundleIdentifier:)` finds `com.google.drivefs` and `com.getdropbox.dropbox`, and `getpwuid` gives the real home (`NSHomeDirectory()` is the container). So the app is "installed" by bundle id, the panel opens at `~/Library/CloudStorage` (the panel runs outside the sandbox, so the owner can see the folders), and the owner picks the account folder and "My Drive". A listing, when it works (tests, an unsandboxed build), only narrows the start folder to the one account. No entitlement is added.
- **The row says where the photos came from.** `SourceConfig.syncedProvider` (`"googleDrive"` or `"dropbox"`, optional text, no migration; a value a version does not know is ignored) and `account` (the e-mail from the `GoogleDrive-<email>` folder name, display only) are set when the picked folder lies inside a provider's synced folder, whichever menu entry was used. Kind stays `localFolder`. Rows and the menu bar card show "Google Drive (trên máy này) · <email>" or "Dropbox (trên máy này)". Logs say only "synced cloud folder import started"; no path or e-mail.
- **Online-only files are read like any file.** Files the provider has not downloaded are dataless placeholders with their real size and dates. The local source opens and reads them with `open`/`read`, which makes macOS download them, so they are neither skipped as empty nor seen as changed. A download that times out or is evicted surfaces as a read error (`EIO`, `ETIMEDOUT`, ...), which is an item-level error: the group waits and is retried like any other read error. The existing disk guard looks at free space on the volume before each export, so a download that fills the disk pauses the import ("chờ chỗ trống"); the provider evicts downloaded copies when macOS needs space. README tells the owner that online-only files are downloaded during the import and need enough space.
- **The browser flow warns first.** The sheet shown before the Google browser flow says that Google will report "chưa xác minh", that this is the owner's own app, to choose Advanced › Go to PhotoVault, and how to avoid it (install Google Drive for desktop, with a link). It is shown every time; "Tiếp tục" / "Huỷ".

## Alternatives

- **Google verification of `drive.readonly`.** Weeks, may be refused, ongoing assessments. Not blocked forever: the web flow stays for people without the desktop app.
- **Always use the web flow and only warn.** Leaves the owner clicking through a "you shouldn't use it" screen for every import.
- **Entitlement for `~/Library/CloudStorage` (temporary exception).** Rejected: a broad file entitlement for a convenience; the panel gives the same access with the owner's explicit pick.
- **A new source kind for synced folders.** Rejected: the engine, bookmark handling and recovery are the Mac-folder ones; one optional field is enough for the label.

## Consequences

- A synced import depends on the desktop app. If it is paused or signed out, files may not download; unreadable files wait and retry.
- Files in "mirror" mode are on disk already; in "stream" mode each file is downloaded when read and counts against disk space until evicted.
- The panel cannot be pre-filled with an account folder inside the sandbox when there are several accounts; the owner picks it.
- Imports of this kind have no token to delete or "Đăng nhập lại" action.
- The bookmark refresh callback now keeps the rest of the stored config (`syncedProvider`, `account`) instead of replacing it.
