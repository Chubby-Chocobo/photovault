---
phase: 02
title: "HTML mockups of every screen"
status: pending
priority: P2
size: M
human_effort: 2-4h
dependencies: []
touches:
  - docs/design/
acceptance:
  - test -f docs/design/mockups/index.html
sources:
  - "spec: file:docs/requirements/photovault-spec-v1.md"
---

# Phase 02: HTML mockups

## Overview
Interactive HTML mockups (Tailwind CDN + Alpine.js) that look like native macOS (SF font stack, vibrancy-like panels, light/dark) for every screen in spec §4.8, §4.1 and §4.9. They are the visual contract for phase 11. Size: M — several pages, no app code.

## Requirements
- `docs/design/mockups/index.html` links every screen; one file per flow:
  - `menu-bar.html` (FR-60): overall status, one row per destination (status enum 8.9.2, pending count, last success), backfill progress (assets done/total, GB uploaded, ETA by asset count), counters pending/deferred/skipped/missingRemote, actions Sync now · Pause/Resume (all or per destination) · Open Drive · Reveal NAS · Recent activity · Settings · Log · Quit. States: active, paused(rootTrashed) with owner prompt, Mac disk critical, offline NAS.
  - `onboarding.html` (FR-01): 9 steps in order, with the sync-mode counts and the note text from FR-06, the "reuse root?" prompt, the summary with the "cần giải phóng X GB" warning.
  - `settings.html` (FR-05 tabs: General, Content, Organization, Places & privacy (FR-85 note), Destinations, Advanced); destination rules editor (FR-72) with the global-ceiling explanation; device group rename/merge (FR-104); view toggles + item estimate (FR-103).
  - `activity.html` (FR-63) and the owner prompts (root missing/trashed, integrity missing, reupload confirm, "Sắp xếp lại" preview count).
- UI copy in Vietnamese (the owner's language), matching the spec's terms.
- `docs/design/README.md`: what each mockup covers and the FR it maps to.

## Implementation Steps
1. Activate `design-mockup-create`; define a small token set (colors, radius, spacing) in a shared `<style>` block.
2. Build each page with realistic sample values (labelled as sample data in the page footer).
3. Publish `index.html` as an artifact for the owner to view.

## Success Criteria
- [ ] Every FR-60 action and every FR-01 step appears.
- [ ] Pages render offline except CDN scripts; layouts sized for the macOS popover and Settings window.

## Risk Assessment
- Mockup and SwiftUI can drift: phase 11 references the mockup per view.

## Audit additions
<!-- Updated: Audit 2026-11-09 -->
- Drop the 375px requirement; target the real macOS sizes (menu popover ~360px wide, Settings window ~720x520). Light and dark kept because macOS apps follow the system appearance.
- Mockups stay (the owner asked for them explicitly); the scope critic's suggestion to drop them is rejected.
