# PhotoVault design

Interactive HTML mockups of every PhotoVault 1.0 screen. They are the visual contract for the SwiftUI views: when a view and its mockup disagree, fix one of them in the same change. Source of truth for behaviour stays `docs/requirements/photovault-spec-v1.md`.

## How to view

Open `mockups/index.html` in a browser. Pages load two pinned CDN scripts (Tailwind `cdn.tailwindcss.com/3.4.16`, Alpine.js `alpinejs@3.14.1` from jsDelivr) and no external images. Every page footer has:

- **Dữ liệu mẫu**: all numbers, names, e-mails and paths are sample values.
- Theme switch (Hệ thống / Sáng / Tối). Default follows `prefers-color-scheme`, like the app follows the system appearance.
- **Chú thích FR** toggle. Purple labels show FR codes and raw enum values (`paused(rootTrashed)`, `missingRemote`). They are developer notes and are not part of the UI.

Panels marked "Mockup" (state switchers, simulation toggles) belong to the mockup tooling, not to the app.

## Screens and FR mapping

| File | Screen (macOS size) | Covers | States / interactions |
|---|---|---|---|
| `mockups/index.html` | Entry page | Links to every screen | — |
| `mockups/menu-bar.html` | `MenuBarExtra` popover, 360 px wide, over a fake menu bar | FR-60 (overall status, one row per destination with enum 8.9.2 + pending + last success, backfill done/total + GB uploaded + ETA by asset count, counters `pending`/`deferred`/`skipped`/`missingRemote`, actions Sync now · Pause/Resume all or per destination · Open Drive · Reveal NAS · Hoạt động gần đây · Settings · Log · Quit), FR-47 root prompt, FR-31/8.5 disk guard, FR-75 offline | State switcher: active backfill · Drive `paused(rootTrashed)` with owner prompt · Mac disk critical · NAS `unavailable(offline)`. Per-destination and global pause work. |
| `mockups/onboarding.html` | Wizard window ~720×560 | FR-01 (9 steps in order), FR-02/03 (sign-in, Keychain), FR-04 (Photos denied → System Settings), FR-06 (asset count per mode, exact note text, no size estimate), FR-07 (fixed archive timezone + live filename example), FR-51/FR-74 reuse prompts, FR-61 notification list, FR-70/71 NAS + Test connection + own scope, FR-15/10/51 start sequence | Toggles: old Drive root exists, NAS has `destination.json`, Mac free-space slider that drives the "Cần giải phóng X GB" warning. |
| `mockups/settings.html` (drawn before decision 0023: still shows the day-folder threshold, "Sắp xếp lại" and the place-name language) | Settings window 720×520, toolbar tabs | FR-05 defaults on tabs Chung · Nội dung · Sắp xếp · Địa danh & riêng tư · Đích · Nâng cao; FR-08 account/root; FR-62 launch at login; FR-20 classification; 8.7 day-folder N + "Sắp xếp lại" with file count; FR-103 view toggles + My Drive item estimate + "Dựng lại view"; FR-104 device group rename (duplicate → suggest merge) and merge; FR-85 privacy note; FR-84/106 geocode progress + "Làm mới địa danh"; FR-72 per-destination rules editor with global ceiling (AND) and change preview; FR-71 remove destination; FR-47/76 "Kiểm tra ngay" | Global switches in Nội dung lock the matching boxes in Đích. Toggles: `drive.file` cannot create shortcuts (views off), library ×3 (item warning). Deep links: `settings.html#advanced`, `#organization`, … |
| `mockups/activity.html` | Window ~680×480 + prompt gallery | FR-63 (rename, move, missing file, status change, restore; filter + search; 500-event cap), owner prompts: root trashed/missing and folder trashed (FR-47: "Khôi phục giúp tôi", "Tôi đã khôi phục", "Upload lại vào thư mục mới"), integrity missing + reupload confirm (FR-47, 8.3 `missingRemote → pending`), new root (FR-08), "Sắp xếp lại" preview (8.7), reuse NAS (FR-74) | Anchors `#prompt-root-trashed`, `#prompt-integrity`, `#prompt-reupload`, `#prompt-new-root`, `#prompt-reorg`, … highlight the target prompt. |
| `mockups/mockup-theme.css` | Shared tokens and controls | SF font stack, system colors light/dark, vibrancy panels, window chrome, switches, segmented control, grouped forms, alerts | — |

## Visual rules

- Native macOS look: system font stack (`-apple-system`, SF Pro), 13 px body, vibrancy via `backdrop-filter`, system accent/green/orange/red, grouped forms like System Settings, NSAlert-style prompts.
- Status always pairs a colored dot with a text label; color is never the only signal.
- Secondary text uses 62 % label alpha so it meets WCAG AA 4.5:1 on both window backgrounds; primary buttons use a darker accent (`#0b6fd9`) for white text.
- Motion: only spinner and short fades; all disabled under `prefers-reduced-motion`.
- Copy in Vietnamese with the spec's terms. "Sync now" stays in English as in the spec. Other FR-60 action names use Vietnamese labels (Mở Google Drive = Open Drive, Mở thư mục NAS trong Finder = Reveal NAS, Xem log = Log, Thoát PhotoVault = Quit).

## Decisions made while building

- No `docs/design/design-system/tokens.json` yet, so the `design-mockup-create` build pipeline (token-generated Tailwind config, compiled CSS, `mockup.json`) was not used. Tokens live in `mockup-theme.css` as CSS custom properties; Tailwind CDN supplies only layout utilities.
- "Cần giải phóng X GB" uses X = `lowWatermark` + 5 GB − free space, because spec 8.5 resumes backfill only at low + 5 GB. It is shown only when free space is below `lowWatermark`.
- "Khôi phục giúp tôi" is offered for a trashed root as well as a trashed sub-folder, since the root is an item the app created (FR-47). A root that is missing (deleted, not trashed) offers only "Tôi đã khôi phục" and "Upload lại vào thư mục mới".
- Under Mac disk critical, destination rows stay `active` (the disk guard is not a destination status) and read "Hoạt động · chờ export".
- The By place view is locked when place names are off, since it needs geocoded cells (FR-106).
- The My Drive item warning threshold (400.000) is a placeholder until the real limit is verified (FR-103 [VERIFY]).
