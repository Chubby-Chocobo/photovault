---
title: "Record renames, moves, status changes and milestones; read the log in the app"
status: in-review
issue: 16
sources:
  - "tracker: github:Chubby-Chocobo/photovault#16"
authoritative: "tracker: github:Chubby-Chocobo/photovault#16"
---

# Plan: activity events and in-app log viewer

Owner request (2026-11-09): do the proposed activity events, and read the log in the app because "Xem log" only opens a Finder folder that a non-technical owner cannot use.

## Phases
| # | Phase | Status |
|---|---|---|
| 01 | [Activity events](phase-01-activity-events.md) | completed |
| 02 | [Log viewer window](phase-02-log-viewer.md) | completed |

## Acceptance criteria
- Renamed, moved, status-changed and milestone events are recorded by the engine, with tests.
- "Xem log" (menu bar) and the Advanced tab open an in-app log window; the folder reveal stays as a button inside it.
- Full `swift test` passes; signed Release build succeeds.

## Decisions

### Status changes are recorded in `DestinationRepository.setStatus`
- Chosen: the store records a `statusChanged` row in the same transaction as the change, so every caller (engine and app) is covered.
- Alternatives: an engine wrapper replacing ~14 call sites (easy to miss one, the app's sign-out path included).
- Why: one place, atomic with the change. The status words move to Core so the store can write them.
- Review later: no

### Routine rows grow one row instead of adding rows
- Chosen: per destination, renames and moves each grow one open row for an hour ("Đã đổi tên 37 thư mục, gần nhất “A” → “B”"; a single change is described in full); uploads grow one row per day ("Hôm nay đã upload 120 file"); a status that flips back within two hours removes its row (Drive full → probe resets to active → full again leaves one row). State lives in `kv` keys `activity_row.*` / `activity_status.*`, dropped with the destination.
- Alternatives: at most 5 rows per pass (review: passes run every round, so a first sync still wrote hundreds of rows); one row per cycle (20–30 a day); stop Health from resetting full/daily-cap (changes retry behaviour).
- Why: the 500 rows kept must hold weeks of rare events (missing files, restores, real status changes).
- Review later: no

### Milestones are a new kind `milestone` ("Tiến độ")
- Chosen: the daily upload row above; one backfill row when, after a drained cycle, no backfill job waits or uploads, no asset waits for classification, and more backfill jobs are done than at the last announcement.
- Alternatives: reuse `notice` (mixes routine progress with things the owner must read).
- Why: own filter chip; notices stay rare.
- Review later: no

### Folder names may appear in activity rows, never in the log file
- Chosen: rename/move rows name day and group folders ("2026-04-26 Hà Nội"); file names and coordinates never appear. The log file keeps its existing redaction.
- Why: the same names are visible on every destination; FR-63/NFR-06 forbid file names and coordinates.
- Review later: no

### Log viewer reads the rotated files directly
- Chosen: `LogReader` in AppSupport parses `photovault.log` and the rotated files (newest 5,000 lines), refreshed when the current file changes; level filter, search, copy, reveal folder.
- Alternatives: OSLogStore (needs entitlement-free access to the app's own entries only on macOS 15+, and the file already holds the redacted copy).
- Why: the file is what support asks for; no new dependency.
- Review later: no

### Log retention and millisecond timestamps (owner, 2026-11-09)
- Chosen: keep the existing size-based rotation (5 × 5 MB, at most 25 MB, oldest deleted) and say so in the log window; timestamps become UTC ISO 8601 with milliseconds; the reader still parses older lines without them.
- Alternatives: add an age limit (does not bound disk use better than the size cap).
- Why: the owner asked that logs never fill the Mac and that times show milliseconds.
- Review later: no

### Default log filter hides per-request detail
- Chosen: filters "Thông thường" (info and above, default), "Cảnh báo & lỗi", "Tất cả chi tiết".
- Alternatives: default to warnings only (the UI check showed an empty window during a normal sync).
- Why: an empty window reads as "the log is broken" to a non-technical owner.
- Review later: no

## Audit Review

### Session — 2026-11-09 (code review of the branch)
| # | Finding | Severity | Disposition |
|---|---|---|---|
| 1 | Progress row every cycle floods the 500 kept | Important | Accept: one upload row per destination per day |
| 2 | 5-row cap is per pass, not per cycle | Important | Accept: hourly open row per kind and destination |
| 3 | Status flapping (full/daily cap reset by Health, flaky network) | Important | Accept: a flip back within 2 h removes the row (owner question decided in auto mode) |
| 4 | Backfill announcement repeats or comes early | Important | Accept: announce on growth of done total; require no provisional assets |
| 5 | Move rows lost on cancellation (GRDB checks cancellation) | Important | Accept: activity writes run in their own task |
| 6 | Log rows' ids shift on reload | Important | Accept: id = line text (+ repeat counter); "Tự cập nhật" toggle |
| 7 | Search folding on the main thread | Important | Accept: folded once off main; filtered list kept in state |
| 8 | Backfill query scans all jobs | Medium | Accept: EXISTS first, count only when announcing |
| 9 | Progress write failure fails the cycle | Medium | Accept: logged, never thrown |
| 10 | Activity keys survive destination removal | Medium | Accept: dropped with dependents |
| M | Count grouping, derived 25 MB, newline split, level badges | Minor | Accept |
| M | Downgrade to 0.1.0 cannot read `milestone` rows | Minor | Reject: single owner, no downgrade path |
