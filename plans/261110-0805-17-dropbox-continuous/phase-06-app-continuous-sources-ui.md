---
phase: 06
title: "App: Nguồn liên tục UI, menu bar, scheduler"
status: pending
priority: P2
size: M
human_effort: 1.5-3h
dependencies: [04, 05]
touches:
  - PhotoVault/App/AppModel.swift
  - PhotoVault/App/AppModel+CloudImports.swift
  - PhotoVault/App/AppModel+ContinuousSources.swift
  - PhotoVault/Engine/AppEnvironment.swift
  - PhotoVault/Engine/CloudImportServices.swift
  - PhotoVault/Engine/SyncScheduler.swift
  - PhotoVault/Views/Settings/SourcesTab.swift
  - PhotoVault/Views/Settings/ContinuousSourceRows.swift
  - PhotoVault/Views/Settings/DropboxFolderSheet.swift
  - PhotoVault/Views/MenuBar/MenuBarView.swift
  - PhotoVault/Views/MenuBar/SourcesSection.swift
  - Sources/PhotoVaultAppSupport/ContinuousSourceText.swift
  - Sources/PhotoVaultAppSupport/ContinuousSourceGuard.swift
  - Sources/PhotoVaultAppSupport/CloudImportSupport.swift
  - Sources/PhotoVaultAppSupport/OverallStatusText.swift
  - Tests/PhotoVaultAppSupportTests/ContinuousSourceTextTests.swift
  - Tests/PhotoVaultAppSupportTests/ContinuousSourceGuardTests.swift
  - Tests/PhotoVaultAppSupportTests/CloudImportSupportTests.swift
  - Tests/PhotoVaultAppSupportTests/StatusTextTests.swift
acceptance:
  - swift test --filter "ContinuousSourceText|ContinuousSourceGuard|CloudImportSupport|StatusText|UITextCoverage"
  - swift test
  - xcodebuild -project PhotoVault.xcodeproj -scheme PhotoVault -configuration Debug build CODE_SIGNING_ALLOWED=NO
---

# Phase 06: App

## Overview
This phase lets the owner add, show, confirm, re-sign and remove continuous Dropbox sources. It opens their adapters at launch, sweeps orphan grants and polls every 15 minutes. Size M: several app files plus small AppSupport types, with no contract change.

## Context
- The ongoing section today shows Photos only: `PhotoVault/Views/Settings/SourcesTab.swift:47-68`. The import menu and the Dropbox sign-out help are at `:93-118`.
- Folder browser: `PhotoVault/Views/Settings/DropboxFolderSheet.swift`. `DropboxBrowserModel` is at `:8-65`, and the sheet title and "Nhập thư mục này" button are in `DropboxFolderSheet.body`.
- Dropbox flows and the token copy: `PhotoVault/App/AppModel+CloudImports.swift:50-109`. Reconnect takes an `ImportSnapshot`: `:128-166`.
- Launch adapters: `PhotoVault/Engine/AppEnvironment.swift:188-206`. It reads `readableImports` and switches on kind; a continuous row would get an import adapter today. Registration: `PhotoVault/App/AppModel.swift:152`. Scheduler conditions: `:177-187`.
- Adapter factory: `PhotoVault/Engine/CloudImportServices.swift:84-89`. Keychain listing helpers: `:43-53`. Account matching: `Sources/PhotoVaultAppSupport/CloudImportSupport.swift:97-112` (`CloudImportKeychain`).
- Timers: `PhotoVault/Engine/SyncScheduler.swift:32-33`. Popover: `PhotoVault/Views/MenuBar/MenuBarView.swift:59-63`. Destination row pattern: `PhotoVault/Views/MenuBar/DestinationsSection.swift`. Header import wording: `Sources/PhotoVaultAppSupport/OverallStatusText.swift:84-86`.

## Requirements
1. Adapters at launch:
   - `CloudImportServices.dropboxContinuousSource(id:rootPath:rootId:)` uses the grant `import-<id>`.
   - `AppEnvironment.openImportSources` takes `mode == .oneTime` rows only.
   - New `openContinuousSources` builds adapters for open continuous rows whose grant exists.
   - `AppModel.goLive` registers both before startup recovery.
2. Orphan grants: `CloudImportKeychain.orphanGrants(stored:rows:)` (pure) lists `import-*` items whose row is missing, or is a `cancelled` continuous row. The app deletes them at launch, with one log line counting them (audit M3).
3. `AppModel+ContinuousSources.swift`:
   - `continuousSources` comes from the snapshot.
   - `addDropboxSource(path:email:)`: run the guard, read the root id (`folderId`, nil for `""`), copy the token, call `addContinuousSource` with `config.remoteRootId`, delete the copy on failure, `requestSync(.manual)`.
   - `removeContinuousSource(id)`: the engine command, then delete `import-<id>`.
   - `confirmLargeRemoval(id)`.
   - `reconnectSource(id:kind:account:)`: `reconnectImport(_:)` becomes a thin wrapper of it (same-account check, `resumeImportAfterSignIn`). The wrapper must not grow `AppModel+CloudImports.swift`.
4. `ContinuousSourceGuard.conflict(account:root:existing:)` (pure): equal or nested roots of the same account are refused (`PathFolding.fold`, with `""` covering everything). Other accounts and sibling folders are allowed.
5. `ContinuousSourceText` (pure) gives a label, tone and detail for each state:

   | State | Text |
   |---|---|
   | Watching, nothing ready | "Đang theo dõi · kiểm tra lần cuối …" |
   | Ready rows | "Đang đọc N file mới" (first listing: "Đang đọc lần đầu: x/y") |
   | Failed rows | "N file chưa đọc được · thử lại mỗi ngày" |
   | `unavailable` | "Không kết nối được, sẽ tự thử lại" |
   | `signInRequired` | "Cần đăng nhập lại" |
   | `rootChanged` | "Thư mục đã bị đổi tên, chuyển hoặc xoá trên Dropbox. Gỡ nguồn này rồi chọn lại thư mục." |
   | `largeRemoval` | "Nhiều file biến mất khỏi Dropbox cùng lúc. Xác nhận nếu bạn đã xoá chúng; ảnh đã sao lưu vẫn ở nguyên." |
   | `diskFull` | "Chờ chỗ trống trên đĩa" |

   It also covers the transfer hold when uploads are held ("Chờ mạng/nguồn điện phù hợp", reusing the existing hold wording where one exists). Display names are "Dropbox · <folder>" or "Dropbox · Toàn bộ Dropbox", with the account on the second line.
6. Settings › Nguồn liên tục:
   - The Photos row as today, then one `ContinuousSourceRow` per source with a dot, label, account, **Đăng nhập lại** / **Xác nhận** when needed, and **Gỡ…**.
   - The **Gỡ…** confirmation reads: "Ngừng theo dõi thư mục này? Ảnh đã upload vẫn ở nguyên ở các đích. Ảnh chưa upload sẽ không được upload. Đích thêm sau sẽ không nhận ảnh của nguồn này."
   - **Thêm nguồn… › Dropbox…** is disabled without an App key, with the same hint as imports.
   - The sign-out help reads "Các nguồn và lần nhập đang có vẫn giữ quyền đọc riêng".
7. `DropboxFolderSheet(purpose: .importOnce | .watch)`:
   - `.watch` titles the sheet "Chọn thư mục Dropbox để theo dõi" and starts in `/Camera Uploads` when it exists.
   - In a folder, the button reads "Theo dõi thư mục này".
   - At the root it reads "Theo dõi toàn bộ Dropbox…" and asks first: "Mọi ảnh và video trong Dropbox sẽ được sao lưu. Mỗi lần một file được sửa, một bản mới được sao lưu thêm."
8. Popover: `SourcesSection` sits above `DestinationsSection` only when `continuousSources` is non-empty. It shows a Photos line and one line per source with an inline action.
9. `OverallStatusText` reads "Đang đọc ảnh từ nguồn" / "Reading photos from sources" when ready rows exist and nothing else is working.
10. `SyncScheduler`:
    - The 15-minute timer also fires while a continuous source is open (`needsSourcePoll`).
    - The 5-minute recheck covers sources with `ready > 0` or `offline/unavailable`, but not rows still waiting out the settle window (audit M6).
11. Every string uses `tr(vi:en:)`. No path, email or id goes in logs.

## Implementation steps
1. Write the red AppSupport tests: text, guard, orphan sweep, and the header case in `StatusTextTests`.
2. Write the AppSupport types, then services, environment, model and views. Build with `xcodebuild`.

## Tests
- The AppSupport tests above, plus `UITextCoverageTests`.
- Manual, by the owner. It needs the Dropbox app from 0.3.0, and runs on a build with the final migration id or a copy of the data folder:
  - Add `/Camera Uploads` and watch the first sync's progress.
  - A new phone photo appears after the poll and settle window. It is not uploaded twice when it is also in iCloud Photos (with HEIC kept as HEIC).
  - Rename and move a file in Dropbox: nothing is uploaded.
  - Delete a file: the backup stays.
  - Rename the watched folder: the row shows "Thư mục đã bị đổi tên…" and nothing is marked deleted.
  - Delete 60 test files: the row shows "Cần xác nhận", and Xác nhận applies the deletions.
  - Disconnect PhotoVault in Dropbox's connected apps: the row shows "Cần đăng nhập lại", and signing in resumes the source.
  - Gỡ: the row is gone, the Keychain item is gone and the backups are kept.

## Risks and rollback
- Unknown: the owner's taste on the popover section and the warning texts; expect a review loop.
- Rollback: revert. Continuous rows then have no adapter and hold as "needs sign-in" until the code returns or the owner resets. Downgrading is not supported (plan.md).
