# Release 0.5.0 changelog notes

## Upgrade notes

- Downgrading to 0.4.x and using "Đăng nhập lại" on a Google Drive import there rewrites the import's settings without its stored location, so after upgrading again that Drive row shows only the folder name (Mac folders find their path again from the bookmark; Dropbox rows are not affected).
- The database gains two empty columns on `import_item` (`fail_count`, `first_failed_at`; migration `v7-import-retry`) so the one-day give-up of an unreadable import file survives relaunches. 0.4.x refuses a database that has been opened by this version, as with every earlier migration.
