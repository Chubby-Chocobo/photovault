# Phase 4: App — History window

- **Touches:** new `PhotoVault/Views/History/*.swift`, `PhotoVault/App/AppModel+History.swift`; `WindowRequest.swift`, `PhotoVaultApp.swift`, `MenuBarLabel.swift`, `MenuBarActions.swift`.
- **Acceptance:** "Lịch sử…" in the menu bar opens the window; Photos, Backfill and Import tabs with filters, paging ("Tải thêm"), a detail pane (status per destination, reason, duplicate, last check, Retry, Show in Finder / Open on Drive), CSV export through `NSSavePanel`, the daily chart (Swift Charts). Reads go through `store.read` off the main thread. `xcodebuild … CODE_SIGNING_ALLOWED=NO build` succeeds.
