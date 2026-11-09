---
phase: 12
title: "Flickr as a continuous source (deferred)"
status: pending
priority: P3
size: L
human_effort: 2-4h
dependencies: [08]
touches:
  - Sources/PhotoVaultFlickr/**
  - Package.swift
  - PhotoVault/Views/Settings/SourcesTab.swift
  - Tests/PhotoVaultFlickrTests/**
acceptance:
  - swift test --filter FlickrSourceTests
---

# Phase 12: Flickr (deferred; owner applies for an API key)

## Overview
This phase backs up the owner's Flickr photos (originals) continuously on the phase 08 runtime. Size L: a new module, OAuth 1.0a signing and polling without a change feed.

## What the owner must provide
- A Flickr API key and secret (non-commercial) from the Flickr App Garden, and an owner decision on shipping the **secret** in the app. OAuth 1.0a has no public-client flow, so the secret ends up in the binary.
- Confirmation that the account can download originals (`url_o`).

## Requirements
- A `PhotoVaultFlickr` module with OAuth 1.0a (HMAC-SHA1) signing, `flickr.people.getPhotos` (`extras=date_taken,geo,original_format,url_o,o_dims,last_update`) and paging.
- Changes by polling `flickr.photos.recentlyUpdated(min_date)` plus a periodic full relist for deletions. Flickr has no change cursor.
- Respect Flickr's per-key request limit with a `TokenBucket` lane.

## Implementation Steps
1. Owner setup. 2. Signing tests against known vectors. 3. Adapter, polling, UI "Thêm Flickr…".

## Success Criteria
- [ ] Stubbed account of 100 photos imported, and an update or deletion detected on the next poll.

## Risk Assessment
- The secret is embedded in the binary; Flickr API terms and limits; `date_taken` granularity flags (approximate dates). Treat a granularity other than exact as a file date.
