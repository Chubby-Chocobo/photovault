---
phase: "08"
title: "App text and docs"
status: completed
priority: P2
size: S
human_effort: 1-2h
dependencies: ["06", "07"]
touches:
  - PhotoVault/Views/Settings/PlacesTab.swift
  - docs/requirements/photovault-spec-v1.md
  - docs/decisions/0028-split-day-by-place.md
  - docs/decisions/README.md
  - docs/architecture/system-architecture.md
  - README.md
acceptance:
  - swift test --filter UITextCoverageTests
  - xcodebuild -project PhotoVault.xcodeproj -scheme PhotoVault -configuration Debug build CODE_SIGNING_ALLOWED=NO
  - grep -q "0028-split-day-by-place" docs/decisions/README.md
  - grep -q "place_slot" docs/requirements/photovault-spec-v1.md
---

# Phase 08: app text and docs

## Overview

Size S: text only. The phase brings the owner-facing note and the living docs in line with the new behaviour.

## Requirements

- `PlacesTab.swift:43` note, through `tr`:
  - vi: "Chỉ đặt tên khi ngày đã kết thúc ít nhất 6 giờ. Ngày có ảnh ở nhiều tỉnh/thành được tách thành một thư mục cho mỗi nơi."
  - en: "Names are added once the day ended at least 6 hours ago. A day with photos in several provinces gets one folder per place."
- Spec, marked "sửa đổi 2026-11-10, issue #27, quyết định 0028":
  - FR-40, FR-81 and FR-83, including the country-only freeze;
  - §8.2 (`asset.place_slot`, `day_place`, `camera/<day>@<slot>`);
  - §8.4 step 9;
  - §8.7.1 and §8.7.4;
  - §8.11: per-group naming; every cell needs `en` once two provinces are known;
  - §8.15.3: binding by id, then name, then fallback; no re-pointing of listed rows; conflicts reported;
  - T28.
- `0028-split-day-by-place.md`, with the usual five sections. It covers the owner's six choices and the plan's Decisions. Its Consequences must say:
  - deleted photos stay in the folder they were in when the day split, so deleted Ninh Bình photos sit in the main folder named "Hà Nội" (audit M8);
  - emptied extra folders remain;
  - country-only mode freezes splits;
  - a "Làm mới địa danh" refresh may regroup and move files. This is the remedy for spurious splits from Apple's data before and after Vietnam's 2025 province merger (audit M10);
  - downgrading to 0.3.0 is unsafe, and later builds refuse a newer schema.

  Add the row to `docs/decisions/README.md`.
- `system-architecture.md`: the step 9 row, `day_place` and `asset.place_slot` in the tables list, the MoveWorker pass cap, the recovery binding row, and the newer-schema guard.
- `README.md`:
  - "Folder layout": an example of a split day, and a line on when splitting happens and that deleted photos are not moved.
  - Under the upgrading notes: "do not downgrade after 0.4.0".

## Steps

Read each doc before editing it, keep Vietnamese spec prose in Vietnamese, and check that links and the FR and section numbers exist.

## Risks

- #24 edits the spec, README and decisions index: rebase, and renumber the ADR if needed.

## Rollback

Revert the doc commit.
