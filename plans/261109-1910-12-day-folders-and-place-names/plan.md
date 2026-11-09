---
title: "Organise destinations by day and fix place-name languages"
status: in-review
priority: P2
issue: 12
branch: feat/12-day-folders-and-place-names
sources:
  - "tracker: github:Chubby-Chocobo/photovault#12"
authoritative: "tracker: github:Chubby-Chocobo/photovault#12"
---

# Plan: day folders everywhere, one place-name rule (issue #12)

Owner request (2026-11-09): "chuyển cách tổ chức folder từ YYYY/MM/DD thành YYYY-MM-DD"; country names in standard English; provinces/cities in Vietnamese inside Vietnam, standard English plus the native name in parentheses abroad. Existing backups are not migrated: the owner wipes the app database and resyncs.

## Outcome

```
<Root>/                                 default root name "PhotoVault"
├── Camera Uploads/
│   ├── 2026-11-07 Đà Lạt/              every camera day is a folder (no YYYY/MM, no N threshold)
│   ├── 2026-10-02 Kyoto (京都市), Japan/
│   └── Unknown date/
├── Screenshots/2026-11-08/   Saved/2026-11-08/
├── By device/Sony A7 IV/2026-11-07/
├── By place/Vietnam/Lâm Đồng/2026-11-07/   By place/Japan/Kyoto (京都府)/2026-10-02/
└── Favorites/2026-11-07/
```
## Phases

| # | Phase | Status | Size | Depends |
|---|---|---|---|---|
| 01 | [Core layout and place-name rule](phase-01-core-layout-and-place-name-rule.md) | completed | M | — |
| 02 | [Engine: every day a folder, second-locale geocodes](phase-02-engine-days-and-geocodes.md) | completed | L | 01 |
| 03 | [Settings and app](phase-03-settings-and-app.md) | completed | S | 02 |
| 04 | [Docs and reset](phase-04-docs-and-reset.md) | completed | S | 03 |

## Acceptance criteria

1. Camera assets go to `<Root>/Camera Uploads/YYYY-MM-DD[ <place>]/`; screenshots and saved to `Screenshots/YYYY-MM-DD/`, `Saved/YYYY-MM-DD/`; undated to `<branch>/Unknown date/`. The default root name is "PhotoVault" (owner, 2026-11-09).
2. Views end in a `YYYY-MM-DD` folder: `By device/<group>/<day>/`, `By place/<country>/<area>/<day>/`, `Favorites/<day>/`.
3. Place names: country = English name; area/locality in Vietnam = Vietnamese; abroad = English, plus ` (<native>)` when the native name differs (case- and diacritic-insensitive). Applies to day folders, By place, sidecars and Drive descriptions.
4. Settings no longer offer the day-folder threshold, "Sắp xếp lại", or the place-name language.
5. `swift test` and the signed build pass; spec, README and a decision record describe the new layout.

## Decisions

### Every day is promoted at its first camera asset
- Chosen: keep the `day_stat.promoted` machinery as "this day has a folder and can be named", with the threshold fixed at 0; the layout puts camera files in the day folder whatever the flag.
- Alternatives: delete promotion (schema, recovery, move planning) — large refactor for no owner-visible gain.
- Why: smallest change that removes moves (the layout no longer depends on the flag) while place naming keeps working.
- Review later: no

### Second geocode per cell under the stored locale `local`
- Chosen: each cell is geocoded in `en` and once more in its own language — `vi` in Vietnam, the country's primary language (`Locale.Language("und-<ISO>").maximalIdentifier`) elsewhere, skipped when that is English. The answer is cached under the locale key `local`.
- Alternatives: a per-country locale key in the cache (query needs the country before it knows the key).
- Why: same request budget as today (two per cell), one simple cache key.
- Review later: yes — a country whose primary language is a poor guess (e.g. India → Hindi)

### The rule is keyed on the place being in Vietnam
- Chosen: Vietnamese names for places in Vietnam; home country only decides whether the day folder gets the country suffix.
- Alternatives: key it on the home-country setting.
- Why: owner confirmed on 2026-11-09.
- Review later: no

### No migration
- Chosen: wipe the app's local database on install; the owner trashes the old root on Drive. Logical paths change freely.
- Alternatives: move jobs from the old layout to the new one.
- Why: owner decision on 2026-11-09; avoids a one-off migration path.
- Review later: no

## Risks

- Recovery from destination (FR-51) parses logical paths; tests with literal paths must move to the new shape.
- Native names with characters Drive accepts but other filesystems dislike: names already pass `NameSanitizer`.

### Default root name "PhotoVault"
- Chosen: the onboarding default root is `PhotoVault` (and `PhotoVault 2` for a second root).
- Alternatives: keep `Camera Uploads`, which would give `Camera Uploads/Camera Uploads/<day>` by default.
- Why: follows from the owner's `Camera Uploads` branch folder; the owner's own root is already named PhotoVault.
- Review later: no

### Metadata fields get one plain name
- Chosen: sidecars (JSON, XMP `photoshop:*`) and Drive descriptions use the rule's names without the parenthesised native name ("Kyoto", "Hà Nội"); folders and views keep "Kyoto (京都市)".
- Alternatives: the combined name everywhere.
- Why: tools such as Lightroom import XMP city/state as a single value.
- Review later: no

## Audit Review

### Session — 2026-11-09
**Findings:** 1 auditor (plan vs code) plus the test-migration agent; 16 findings (2 High, 10 Medium, 4 Low).

| # | Finding | Severity | Disposition | Applied To |
|---|---|---|---|---|
| H1 | Recovery parsers (`LocalTreeInterpreter`, `RemoteInventoryLoader.dayFolder`) only read `YYYY/MM/day` | High | Accept: both read `Camera Uploads/<day>[ place]`, `<branch>/<day>`; tests added | Phase 02 |
| H2 | Days whose filtered count is 0 (only videos/hidden) never promoted → never named | High | Accept: promote on any camera asset of the day | Phase 02 |
| M1 | Install order: old root offered for reuse; WAL/backups survive a db-only delete | Medium | Accept: trash the old root before onboarding; move the whole data folder aside | Phase 04 |
| M2 | Phase acceptance checks cannot pass separately | Medium | Accept: phases land together; full suite + signed build gate the branch | Process |
| M3 | Country-only fallback shows ISO code / Vietnamese country | Medium | Accept: English country name from the ISO code | Phase 01 |
| M4 | Native-language guess (CH, BE, CA…) and geocoder fallback to the Mac language | Medium | Partly: Vietnamese answers abroad are discarded; per-country overrides deferred (Review later: yes) | Phase 01, Decisions |
| M5 | `local` cache key hides the language asked | Medium | Reject: fresh database, fixed rule; "Làm mới địa danh" re-asks every cell | — |
| M6 | Combined names in XMP/JSON metadata | Medium | Accept: plain names in metadata | Decisions, Phase 02 |
| M7 | PlaceNamer polls every waiting day each pass | Medium | Accept: only `pending` days are polled; waiting days return via the dirty queue when a cell's answer arrives | Phase 02 |
| M8 | Docs missed (spec §8.2/8.4/8.11/8.15, sidecar schema, architecture, 0019) | Medium | Accept; design mockups left as historical drafts | Phase 04 |
| M9 | Nothing stops a new build opening an old-layout database | Medium | Reject: single owner, reset done as part of this install, documented in 0023 and README | — |
| M10 | Root rename not in the plan | Medium | Accept: recorded as a decision | Decisions |
| L1 | By place area folders created in English then renamed | Low | Accept: a cell joins By place once both answers are in | Phase 02 |
| L2 | Refresh estimate assumes one request per cell | Low | Accept: two | Phase 03 |
| T1 | Places tab example literal outside a pair | Low | Accept: verbatim constant | Phase 03 |
| T2 | Country-only fallback named "Việt Nam" in Vietnam | Low | Accept: "Vietnam" (same fix as M3) | Phase 01 |

### Whole-Plan Consistency Sweep
Plan, phases, spec and README describe `Camera Uploads/<day>`; searched for `YYYY/MM`, `dayFolderThreshold`, `placeNameLanguage`, `Sắp xếp lại`, `resort` in Sources/PhotoVault/docs (outside mockups and this table): none. Unresolved contradictions: none.
