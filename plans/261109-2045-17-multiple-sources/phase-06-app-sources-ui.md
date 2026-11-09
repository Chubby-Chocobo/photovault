---
phase: 06
title: "App: Sources tab and import UI"
status: pending
priority: P2
size: M
human_effort: 1-2h
dependencies: [05]
touches:
  - PhotoVault/App/WindowRequest.swift
  - PhotoVault/App/AppModel.swift
  - PhotoVault/App/AppModel+Sources.swift
  - PhotoVault/Views/Settings/SettingsView.swift
  - PhotoVault/Views/Settings/SourcesTab.swift
  - PhotoVault/Services/FolderPicker.swift
  - PhotoVault/Engine/AppEnvironment.swift
  - Sources/PhotoVaultAppSupport/ImportProgressText.swift
  - Tests/PhotoVaultAppSupportTests/**
acceptance:
  - swift test --filter ImportProgressTextTests
  - swift test --filter UITextCoverageTests
  - swift test --filter PhotoVaultAppSupportTests
  - xcodebuild -project PhotoVault.xcodeproj -scheme PhotoVault -configuration Debug build CODE_SIGNING_ALLOWED=NO
---

# Phase 06: App, Sources tab and import UI

## Overview
This phase adds the owner-facing part: a Settings tab "Nguồn / Sources" with Photos and the import jobs, the "Nhập từ thư mục… / Import from folder…" action, live progress, cancel, and source registration at launch. Size M: app target plus one AppSupport file, using a known pattern (the Destinations tab and `FolderPicker`).

## Requirements
- Functional:
  - `SettingsTab.sources` (`PhotoVault/App/WindowRequest.swift:4`), placed before `destinations`. Title `tr(vi: "Nguồn", en: "Sources")`, symbol `tray.and.arrow.down`. `SettingsView` (`SettingsView.swift:31`) gets the `case .sources: SourcesTab()` branch.
  - `SourcesTab`:
    - Section "Nguồn chính": one Photos row with the authorization state and "Liên tục: ảnh mới được sao lưu khi xuất hiện trong Photos".
    - Section "Nhập một lần": a button that is disabled until the baseline is taken (note why), and one row per `EngineSnapshot.imports` item. Each row shows the folder display name, the status text, a `ProgressView(value: processed, total: found)` while scanning, then `filesUploaded/filesTotal` while importing, the counts line, and a "Huỷ" button with a confirmation dialog while scanning, importing or offline.
    - A note: "Giữ thư mục và ổ đĩa chứa nó kết nối cho tới khi nhập xong. PhotoVault chỉ đọc, không sửa hay xoá gì trong thư mục."
  - `FolderPicker.chooseImportFolder()`: like `chooseFolder` (`FolderPicker.swift:16`) but with `canCreateDirectories = false`, prompt "Nhập", and the bookmark made with `readOnly: true` (phase 04).
  - `AppModel+Sources.swift`:
    - `importFolder()`: pick, build `LocalFolderSource(id: .folder(UUID()), root: SecurityScopedBookmarkRoot(bookmark:…), metadata: ImageIOMetadataReader())`, call `coordinator.startFolderImport`, trigger a sync.
    - `cancelImport(id)`.
    - Errors go through `ErrorText`.
  - `AppEnvironment` (`AppEnvironment.swift:159-167`): pass `sources:` into `EngineEnvironment`. At launch, before `coordinator.start()`, build a `LocalFolderSource` for every source row that is not completed or cancelled and that has a bookmark, then call `registerSources`. A stale bookmark is refreshed through `onRefresh`, which writes the source `config_json` (as destinations do).
  - `ImportProgressText` (AppSupport, pure): status labels (`scanning` "Đang đọc thư mục…", `importing` "Đang tải lên…", `offline` "Thư mục không truy cập được, sẽ tiếp tục khi có lại", `completed`, `cancelled`) and the counts line with `L10n.plural`.
- Non-functional: every string is `tr(vi:en:)` (`UITextCoverageTests`). The view model is `@MainActor`. Bookmark resolution happens off the main thread (`FolderPicker.resolvedURL` note, `FolderPicker.swift:33`).

## Architecture
The view reads `model.snapshot.imports`, which is published by the coordinator. Commands go through `AppModel` to `SyncCoordinator`. The Xcode project uses a synchronized root group (`project.pbxproj:24`), so new files need no project edit.

## Related Code Files
- Create: `PhotoVault/App/AppModel+Sources.swift`, `PhotoVault/Views/Settings/SourcesTab.swift`, `Sources/PhotoVaultAppSupport/ImportProgressText.swift`
- Modify: `WindowRequest.swift`, `AppModel.swift` (expose imports from the snapshot if not already generic), `SettingsView.swift`, `FolderPicker.swift`, `AppEnvironment.swift`

## Implementation Steps
1. Tests first: `ImportProgressTextTests` (vi/en via `L10n.$override`, plural forms, all statuses). Extend `UITextCoverageTests` if it lists files.
2. Write `ImportProgressText`.
3. Write the tab, the picker and the AppModel actions. Wire `AppEnvironment` (sources registry and launch registration).
4. Build unsigned. Manual E2E with the signed build:
   - import a camera folder (ARW+JPG), an iPhone export (HEIC+MOV), screenshots and chat-app JPEGs into a local destination and Drive;
   - quit mid-import and relaunch;
   - unplug the external disk mid-import;
   - cancel one job;
   - check Recent activity.

## Success Criteria
- [ ] The AppSupport suite and the unsigned build pass.
- [ ] Manual E2E: the folder layout matches the same photos backed up from Photos; relaunch, unplug and cancel behave as phase 05 describes; one activity row per finished job.

## Risk Assessment
- The sandbox and a read-only bookmark on SMB/NAS volumes: `.securityScopeAllowOnlyReadAccess` on network volumes is `[UNVERIFIED]`. If it fails, fall back to a read-write bookmark: the entitlement already exists (`Config/PhotoVault.entitlements`), and the adapter never writes anyway.
- Settings window size (720×560): the list may need its own scroll area for many jobs.
