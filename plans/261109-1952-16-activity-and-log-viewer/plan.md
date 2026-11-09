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

### Renames and moves are summarised per pass and destination
- Chosen: up to 5 lines per pass (one per rename, one per target folder of moves); above that one summary line with the count and one example.
- Alternatives: one row per file or folder (a first sync renames thousands of day folders and would push out every other event of the 500 kept).
- Why: the activity list must stay readable and keep the rare events.
- Review later: no

### Milestones are a new kind `milestone` ("Tiến độ")
- Chosen: one row per destination at the end of a cycle that uploaded files; one row when a destination's backfill (`backfill`/`destinationBackfill` jobs) has nothing pending left after a drained cycle, announced once until new backfill work appears.
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
