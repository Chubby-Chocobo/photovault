# Phase 3: AppSupport — presentation logic

- **Touches:** new `Sources/PhotoVaultAppSupport/HistoryText.swift`, `HistoryFilters.swift`, `HistoryCSV.swift`, `HistoryTimeline.swift`, `HistoryLinks.swift`, `HistoryRunText.swift`; `Tests/PhotoVaultAppSupportTests/History*Tests.swift`.
- **Acceptance:** tests for filter building (time presets with an injected now and calendar, search trimming), per-destination status text, reason text, CSV escaping (comma, quote, newline, Unicode, formula prefix), timeline days across time zones and DST, run and import summaries; every string is `tr(vi:en:)` and `UITextCoverageTests` passes.
