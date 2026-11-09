---
title: "Factory Reset: start over from onboarding"
status: in-review
issue: 15
sources:
  - "tracker: github:Chubby-Chocobo/photovault#15"
authoritative: "tracker: github:Chubby-Chocobo/photovault#15"
---

# Plan: Factory Reset

Owner request (#15): a Factory Reset that returns the app to onboarding; the old Drive folder stays and the owner deletes it by hand; after onboarding, data syncs into a new folder.

## Phases
| # | Phase | Status |
|---|---|---|
| 01 | [Reset on next launch](phase-01-reset-on-next-launch.md) | completed |

## Acceptance criteria
- Settings › Nâng cao has "Đặt lại từ đầu…" with a confirmation that says what is deleted and what stays.
- Confirming signs out of Google, then the app relaunches into onboarding with an empty database; nothing at any destination is touched.
- A reset interrupted by a crash completes at the next launch.
- `swift test` passes; signed Release build succeeds; checked on screen.

## Decisions

### The wipe happens at the next launch, holding the instance lock
- Chosen: confirming writes a marker file `factory-reset-requested` in the data folder and relaunches the app; the new process waits for the old one's lock (up to 15 s), deletes the data folder's contents before opening the database, removes the marker last, and goes to onboarding.
- Alternatives: closing the database and rebuilding the environment in-process (the composition root is built once; every service would need a teardown path).
- Why: nothing has the database open while it is deleted; a crash mid-wipe retries at the next launch.
- Review later: no

### What is kept
- Chosen: the interface language (UserDefaults) and `drive-daily-cap.json` (Google counts the 750 GB/day per account, not per database).
- Alternatives: delete everything.
- Why: the language is a display preference; dropping the cap counter would let a fresh sync hit Google's limit as errors.
- Review later: no

### Google sign-out first
- Chosen: the refresh token is removed from the Keychain (and revoked at Google when reachable) before the marker is written; if removing it fails, the reset stops with an error.
- Alternatives: wipe without signing out.
- Why: the Keychain is outside the data folder, so a wipe alone would keep the old account signed in.
- Review later: no

### Destinations are not touched
- Chosen: no file or folder at Drive or NAS is deleted or renamed; the confirmation tells the owner to delete the old Drive folder by hand (and the NAS folder, if any) before onboarding, otherwise onboarding offers to reuse it.
- Why: the app never deletes backup data (spec principle); #15 accepts the manual step.
- Review later: no

## Audit Review

### Session — 2026-11-09 (code review of the branch)
| # | Finding | Severity | Disposition |
|---|---|---|---|
| 1 | Failed relaunch ignored; app quits silently | Important | Accept: await `openApplication`; on error stay open and tell the owner to reopen |
| 2 | Dev build relaunches without `--dev-container` | Important | Accept: pass the launch arguments on |
| 3 | No double-run guard or progress during sign-out | Important | Accept: in-progress flag disables the button; "Đang đặt lại…" notice |
| 4 | Lock wait blocks the main thread at launch | Minor | Reject: only on the reset path, before any UI; the marker survives a timeout |
| 5 | Failure path resumes a sync the owner had paused | Minor | Accept |
| 6 | Drive not marked signed out if the marker write fails after sign-out | Minor | Reject: the marker is written inside the app's own container; the next cycle reports sign-in required |
| 7 | A wipe that keeps failing blocks every launch | Minor | Accept: the alert names the folder to empty by hand |
| 8 | `fileLog.close()` is pointless | Minor | Accept: removed |
| 9 | Docs overstate the revoke | Minor | Accept |
| 10 | Root-run test, symlink coverage | Minor | Accept: root guard; symlink test added |
| 11 | Daily cap not tied to an account | Minor | Accept as documented in README |
| 12 | Delivered notifications stay | Minor | Reject: harmless |
