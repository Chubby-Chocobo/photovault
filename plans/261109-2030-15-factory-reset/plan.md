---
title: "Factory Reset: start over from onboarding"
status: in-progress
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
| 01 | [Reset on next launch](phase-01-reset-on-next-launch.md) | in-progress |

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
- Chosen: the refresh token is revoked and removed from the Keychain before the marker is written; if that fails, the reset stops with an error.
- Why: the Keychain is outside the data folder, so a wipe alone would keep the old account signed in.
- Review later: no

### Destinations are not touched
- Chosen: no file or folder at Drive or NAS is deleted or renamed; the confirmation tells the owner to delete the old Drive folder by hand (and the NAS folder, if any) before onboarding, otherwise onboarding offers to reuse it.
- Why: the app never deletes backup data (spec principle); #15 accepts the manual step.
- Review later: no
