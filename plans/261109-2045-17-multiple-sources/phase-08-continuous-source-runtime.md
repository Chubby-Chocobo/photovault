---
phase: 08
title: "Continuous non-Photos source runtime (deferred)"
status: pending
priority: P3
size: L
human_effort: 3-6h
dependencies: [05]
touches:
  - Sources/PhotoVaultCore/Protocols/ContentSource.swift
  - Sources/PhotoVaultCore/Models/SourceModels.swift
  - Sources/PhotoVaultStore/Schema+Sources.swift
  - Sources/PhotoVaultEngine/ContinuousSourceStage.swift
  - Sources/PhotoVaultDrive/KeychainStore.swift
  - Tests/PhotoVaultEngineTests/**
acceptance:
  - swift test --filter ContinuousSourceTests
  - swift test
---

# Phase 08: Continuous non-Photos source runtime (deferred, not this round)

## Overview
This phase provides the shared machinery that Dropbox, Flickr and another Google account need before any of them can be added: change cursors, baselines and edits/deletions for long-lived sources other than Photos. Size L: a new contract, a migration and credential storage for several accounts.

## Requirements
- `protocol ContinuousSource: ContentSource`: `currentCursor()`, `changes(since:) -> (upserted: [RemoteItem], deleted: [itemId], next: cursor)` (`.cursorExpired` → full relist, like Reconciler), and `RemoteItem { itemId, revision, name, size, contentHash?, capturedAt?, location?, … }`.
- Keys `s:<sourceId>/<itemId>` (the decision in plan.md). A new revision of an original never overwrites the uploaded file ("Không bao giờ ghi đè file gốc"). It becomes a new asset keyed `s:<sourceId>/<itemId>@<revision>`, and the old one stays. Review this with the owner when the phase starts.
- Per-source baseline and `inserted_at` semantics (spec 8.8 per source); cursor stored on `source` (new column `cursor`, migration v6); deletions only set `deleted_at`.
- Scheduler: poll every 15 min while the app runs, plus provider push or longpoll where it exists. Per-provider request budgets go through `TokenBucket`.
- Credentials: `KeychainStore` keyed by `(provider, accountId)`. Today it holds one Google account (decision 0010).
- Dedupe before download when the provider gives a hash (Drive `md5Checksum`, Dropbox `content_hash`): a `resource.md5` index plus provider-hash comparison.

## Related Code Files
- Create: `Sources/PhotoVaultEngine/ContinuousSourceStage.swift`
- Modify: Core protocols and models, the Store schema, `KeychainStore`

## Implementation Steps
1. Tests first with a `FakeContinuousSource`: insert, update (new revision), delete, cursor expiry, offline.
2. Write the protocol, migration, stage and Keychain keys.

## Success Criteria
- [ ] A fake source with 3 cycles of changes produces the expected assets, and no original is overwritten.

## Risk Assessment
- The revision-as-new-asset rule doubles storage for edited cloud files; that is an owner decision. The provider APIs differ widely, so keep the protocol minimal and grow it per provider.
