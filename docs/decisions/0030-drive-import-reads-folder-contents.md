# 0030 Google Drive import reads folder contents with drive.readonly

- **Status:** Accepted
- **Spec refs:** FR-119 (amended), FR-122 (amended), FR-123 (amended); supersedes the Google Drive scope and picked-folder parts of [0026](0026-cloud-folder-imports.md)
- **Review trigger:** Google changes what `drive.file` grants for a picked folder, the `drive.readonly` consent or verification rules change, or the owner wants imports that keep their sign-in after they finish

## Context

Decision 0026 shipped the import with `drive.file` only and listed the risk that a picked folder would not reveal its existing children. Version 0.3.0 confirmed it: the live log showed `files.list` for a picked folder answering 200 with an empty list, and the import "completed" with 0 files. Under `drive.file`, picking a folder grants the folder itself, not what is inside it.

## Decision

- **Import sign-in asks for `drive.file` and `drive.readonly`.** `drive.file` stays so the Picker's per-file grants keep working. `drive.readonly` lets the app list and download everything inside the folders the owner picked. The Picker parameters (`trigger_onepick`, `allow_multiple`, `allow_folder_selection`) do not change. The owner still chooses files and folders in the Picker; the app reads only the picked items and what is below picked folders, and only issues GET requests.
- **The backup destination keeps `drive.file` only.** Its sign-in, its scope check and its consent text do not change. A test pins both scope strings.
- **Recursion.** Picked folders are listed to their full depth (with `nextPageToken` paging and shared-drive flags). Docs, shortcuts, trashed items and files with an `appProperties` key starting `pv` are skipped. A file picked on its own and also found inside a picked folder is read once, under the deeper path.
- **The import grant is short-lived.** When an import is completed or cancelled and none of its files has an upload pending, uploading or deferred, the app deletes its `import-<id>` Keychain item and drops its adapter. The engine names such imports (`closedImportsReadyToRelease`); the app deletes the items after each cycle, so a crash between the two is repaired by the next cycle. The same rule applies to Dropbox imports, because they use the same Keychain item and the same sign-in-again flow. A destination added later asks the owner to sign in again through the existing "Đăng nhập lại" flow (FR-121); Google then shows the consent again.
- **An empty import says so.** An import of any kind whose listing finds no photo or video ends as completed, with the reason "the folder had no photos or videos the app could read" in Settings, the notification and the activity line. A Google Drive import adds the hint to sign in again and pick the folder again, because an import made with 0.3.0 only had `drive.file`. Names, ids and emails stay out of logs.

## Alternatives

- **Keep `drive.file` and ask the owner to select the photos inside the folder (⌘A).** Rejected by the owner (2026-11-10): easy to get wrong and silent when it is.
- **Request `drive.readonly` for the backup destination too.** Rejected: the destination needs no read access outside its own files.
- **Keep the import grant after the import.** Rejected: a broad read grant for no purpose. The cost is one more sign-in when a destination is added later.

## Consequences

- Google shows "See and download all your Google Drive files" on the import consent. `drive.readonly` is a restricted scope: the app stays unverified, which is fine for personal use (the owner clicks through the unverified-app warning). The owner must add the scope on the OAuth consent screen (Data access) in the Cloud Console.
- Imports made with 0.3.0 hold a grant without `drive.readonly`. They are not repaired: the owner imports the folder again. A new import gets a new id and does not collide with the empty one.
- A deferred upload that never recovers (for example a file too large for the disk) keeps the import grant until the owner cancels or the job ends.
- The one-time cost of an extra sign-in when a destination is added after an import ended.
