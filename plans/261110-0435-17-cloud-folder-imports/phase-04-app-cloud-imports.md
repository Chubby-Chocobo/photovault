---
phase: 04
title: "App: entries, auth flows, Dropbox browser, registration"
status: pending
priority: P2
size: M
human_effort: 1-2h
dependencies: [02, 03]
touches:
  - PhotoVault/**
  - Config/**
  - PhotoVault.xcodeproj/**
  - Sources/PhotoVaultAppSupport/**
  - Tests/PhotoVaultAppSupportTests/**
acceptance:
  - swift test --filter AppSupport
  - xcodebuild -project PhotoVault.xcodeproj -scheme PhotoVault -configuration Release build
---

# Phase 04: App

## Requirements
- "Nhập ảnh…" menu items:
  - Từ thư mục trên Mac…
  - Từ Google Drive…
  - Từ Dropbox… (disabled, with a hint, when `PVDropboxAppKey` is empty)
- Google:
  - An explainer sheet before the browser opens: pick photos, videos or folders; inside a folder, select the photos (⌘A), because Google may not let the app read a folder's contents.
  - Then run the Picker flow and store the token as `import-<id>`.
  - Display name: the single picked folder's name, otherwise "N mục từ Google Drive".
  - Start the import with `kind .googleDrive`, the account email and the picked ids.
- Dropbox:
  - Sign in when there is no `dropbox-account` token.
  - A folder browser sheet: breadcrumb, folders only, "Nhập thư mục này", and the whole Dropbox at the root.
  - Copy the token to `import-<id>`, then start the import.
  - "Đăng xuất Dropbox" in Settings › Nguồn.
- At launch, register cloud imports from `readableImports` whose Keychain token exists.
- Factory reset deletes `import-*` and `dropbox-account`.
- Rows and the menu card show the provider label ("Google Drive · email", "Dropbox · email", "Thư mục trên Mac"). A `signInRequired` row offers "Đăng nhập lại", which reruns the flow and replaces the token.
- An import that found 0 files from Google Drive shows the "chọn ảnh bên trong thư mục" hint.
- Config:
  - `DROPBOX_APP_KEY` goes in Base.xcconfig (empty), the Secrets example and the Info.plist key `PVDropboxAppKey`.
  - Check the network client/server entitlements.
- All text comes through `tr(vi:en:)`.
