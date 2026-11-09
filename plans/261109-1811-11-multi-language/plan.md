---
title: "Support English and Vietnamese with an in-app language switch"
status: in-review
priority: P2
issue: 11
branch: feat/11-multi-language
sources:
  - "tracker: github:Chubby-Chocobo/photovault#11"
authoritative: "tracker: github:Chubby-Chocobo/photovault#11"
---

# Plan: UI in English and Vietnamese (issue #11)

Issue #11: "Hỗ trợ tiếng Anh và tiếng Việt, có chỗ để switch giữa các ngôn ngữ."

## Outcome

PhotoVault's interface (menu bar, windows, Settings, onboarding, notifications, error and activity text) is available in Vietnamese and English. Settings → General has an **Interface language** picker (System / Tiếng Việt / English) that switches at once, without a restart. The default stays Vietnamese.

## Scope

- In: user-visible text in `PhotoVault/` (app target), `Sources/PhotoVaultAppSupport/`, and activity messages written by `Sources/PhotoVaultEngine/`; number grouping and region names follow the interface language.
- Out (never localized): anything written to destinations — root folder name ("Camera Uploads"), view folders ("By device", "By place", "Favorites"), day/place folder names, sidecars — and the place-name language (Settings → Places, spec FR-82 / §8.8), logs (English), docs, website. Activity events already stored keep the language they were written in.

## Phases

| # | Phase | Status | Size | Depends |
|---|---|---|---|---|
| 01 | [Language core and coverage test](phase-01-localization-core-and-checks.md) | completed | M | — |
| 02 | [AppSupport and Engine text](phase-02-appsupport-and-engine-text.md) | completed | L | 01 |
| 03 | [App target text](phase-03-app-target-text.md) | completed | L | 01 |
| 04 | [Language picker and live switch](phase-04-language-picker-and-launch.md) | completed | M | 01, 03 |
| 05 | [Docs and verification](phase-05-docs-and-verification.md) | completed | S | 02, 03, 04 |

02 and 03 own disjoint files; both only add `tr(vi:en:)` calls and need nothing from each other.

## Acceptance criteria

1. In English, no Vietnamese text that comes from PhotoVault itself appears in the menu bar, Settings, onboarding, notifications or error banners (owner data such as device-group, destination and place names, activity stored before the switch, and the endonym "Tiếng Việt" excepted); activity recorded after the switch is English. Checked on a fresh dev container.
2. In Vietnamese (the default) every screen reads exactly as today: the Vietnamese literals are kept verbatim as the `vi:` side, and the existing tests that assert Vietnamese pass unchanged.
3. Changing the interface language in Settings updates every open window and the menu at once and persists across launches.
4. `UITextCoverageTests` passes: no Vietnamese string literal in UI code outside a `vi:` argument (or a line marked `// l10n: verbatim`).
5. Destination names do not depend on the interface language (test: onboarding root name and view folder names identical under `vi` and `en`).
6. `swift test` and the signed app build pass.

## Decisions

- **Inline pairs, not String Catalogs.** Every UI string becomes `tr(vi: "…", en: "…")`. Chosen because SwiftPM (`swift test`, CI) copies `.xcstrings` without compiling them (audit, verified with the local toolchain), so package catalogs would not resolve in tests; and because a pair cannot miss a translation, keeps today's Vietnamese byte-for-byte, and needs no extraction tooling. Alternative: catalogs in the app target plus `.strings` in packages — two mechanisms, hand-maintained keys, silent fallbacks. Review later if a third language is wanted.
- **Live switch, no restart.** The language is a process-wide value read at render time; scenes re-render on change. A restart would fight the single-instance lock (`InstanceLock` is non-blocking) and could leave no instance running (audit).
- **Tests never set the global.** `L10n.$override` (a `@TaskLocal`) pins the language inside one test; the default is `vi`.
- **Default Vietnamese**; "System" picks Vietnamese when the Mac's preferred languages put Vietnamese first, else English.
- **Stored in UserDefaults** (`PVInterfaceLanguage`): a per-Mac UI preference needed before the database opens; `GlobalSettings` uses synthesized `Codable`, so a new field would break decoding of stored settings.
- **The place-name language stays a separate setting** (renaming folders on destinations takes hours and is a data change; switching the UI must not trigger it). Both pickers get distinct labels. Owner may revisit.
- **`VietnameseFormat` keeps its name and signatures**; its digit grouping follows the interface language. Avoids churn in 22 files; the name is documented as historical.
- **Info.plist Photos usage text** becomes one bilingual sentence pair (the system shows it once, before the app can choose a language).

## Risks

- ~650 literal lines across ~75 files: mechanical but large; translation quality needs the owner's skim of the English screens.
- Strings computed once and cached (e.g. stored in model state) would not re-render on switch; phase 04 checks each window after a switch.

## Audit Review

### Session — 2026-11-09
**Findings:** 23 raw from 3 reviewers (failure modes, assumptions, scope/security), 13 after de-duplication; all with file:line or toolchain-experiment evidence.
**Severity breakdown:** 1 Critical, 7 High, 5 Medium. All accepted; the plan was redesigned rather than patched.

| # | Finding | Severity | Disposition | Applied To |
|---|---|---|---|---|
| 1 | `swift test` copies `.xcstrings` uncompiled (verified on Swift 6.3.2) — package catalogs never resolve in CI | Critical | Accept: inline `tr(vi:en:)` pairs, no catalogs | Decisions, all phases |
| 2 | Resource folders declared before they exist break the build | High | Accept: moot, no resources | Phase 01 |
| 3 | "Restart now" vs non-blocking single-instance lock can leave no instance running | High | Accept: live switch, no restart | Decisions, Phase 04 |
| 4 | Process-wide language set by tests races parallel Swift Testing | High | Accept: `@TaskLocal` override, tests never set the global | Phase 01, 02 |
| 5 | First-launch default and `App.init` ordering | High | Accept: preference read in `AppModel.init`, live re-render | Phase 04 |
| 6 | English-source keys put the default Vietnamese UI at risk; `String`-typed component params and ternaries escape catalogs and checks | High | Accept: Vietnamese literal kept verbatim as `vi:`; pairs are plain Strings | Decisions, Phase 02, 03 |
| 7 | Destination-name strings (Camera Uploads, view folders) could get translated | High | Accept: listed as never wrapped + test | Scope, Phase 02, 03, AC5 |
| 8 | Missing-key detection absent | Medium | Accept: impossible by construction | Decisions |
| 9 | `VietnameseFormat` rename churn and 02/03 coupling | Medium | Accept: keep name, language-aware grouping in Phase 01 | Phase 01 |
| 10 | AC1 unachievable (stored activity, owner data, endonyms, hardcoded `vi` region names) | Medium | Accept: AC1 reworded; region names follow UI language | AC1, Phase 03 |
| 11 | Two "language" pickers confusable; place-name change renames folders | Medium | Accept: distinct labels + note; kept separate (owner may revisit) | Decisions, Phase 03 |
| 12 | Python checker/allowlist/warn-only CI and UserDefaults preference are extra machinery | Medium | Partly: checker replaced by a Swift test with a line marker; UserDefaults kept (needed before the DB opens; `GlobalSettings` synthesized `Codable` cannot take a new field safely) | Phase 01, Decisions |
| 13 | Plurals need the raw `Int`; fallback literals inside interpolations escape | Medium | Accept: `L10n.plural` with `Int`; every literal is a pair | Phase 01, 02 |

### Whole-Plan Consistency Sweep
Searched all plan files for: xcstrings, catalog, AppleLanguages, restart, relaunch, DisplayFormat, check-localizations, allowlist, AppLanguagePreference, developmentRegion, defaultLocalization. Remaining mentions are only in this audit table and the Decisions rationale (as rejected options). Phase touches and acceptance match the inline-pair design. Unresolved contradictions: none.

## Validation

Run in auto mode (no interview): each open question was decided by the stated principles and recorded under Decisions — default language (Vietnamese, today's behaviour), switch mechanism (live), storage (UserDefaults), place-name language (separate, owner may revisit), destination names (never localized). Open questions for the owner: none blocking; the place-name/interface language separation can be revisited.
