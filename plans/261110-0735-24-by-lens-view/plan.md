# By lens view

## Overview

A fourth Drive view, `By lens/<lens name>/<YYYY-MM-DD>/`, grouping camera photos by the lens that took them. Off by default so an update does not create thousands of shortcuts. Issue 24, branch `feat/24-by-lens-view` into `release/0.4.0`.

## Decisions

| Topic | Chosen | Alternatives | Why | Review later |
|---|---|---|---|---|
| Lens name | EXIF LensModel, trimmed and whitespace-collapsed; phone "X back ... camera R" becomes "X R", "X front ... camera R" becomes "X front R"; `f/N` written `fN`; placeholder values ignored | Raw EXIF; a lens table like device names | Apple strings are long and noisy, other lenses are already readable; no table to maintain | Owner asks for rename or merge |
| Grouping key | Normalised name, lowercased, hashed like device groups | Raw string | Case and spacing variants collapse into one folder; logical path never carries a name | Same |
| Membership | `camera` category with a non-empty lens model; deleted-from-Photos keeps its shortcut | Include other categories; "Unknown" folder | Same as By device; an Unknown folder is noise | - |
| Default | `viewByLensEnabled` false; old settings JSON without the key decodes to false | On | No surprise item growth on My Drive | - |
| Toggle off | Existing semantics: tree kept, on again backfills, "Dung lai view" repairs | Trash on off | Matches FR-103 and the other views | - |
| Rename / merge groups | Deferred | Same UI as device groups | Not needed yet | When asked |
| Schema | No migration: `shortcut.view` is plain text with no check constraint | - | Verified in Schema.swift | - |

## Phases

| Phase | Name | Status |
|---|---|---|
| 1 | Core: ViewKind, LensNameResolver, ViewRules, layout, setting (tests first) | Completed |
| 2 | Engine: planner enables the view; engine tests | Completed |
| 3 | App: Settings toggle, estimate, texts | Completed |
| 4 | Docs: spec FR-107, README, decision 0027 | Completed |

## Acceptance

- Shortcuts appear under `By lens/<name>/<day>/` only when enabled; none by default.
- Name variants collapse; Apple names shortened as decided.
- Deleted-from-Photos asset keeps its shortcut; rebuild restores it.
- Existing settings decode with the view off.
- `swift test` and the Release xcodebuild pass.
