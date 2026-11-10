# Spike #31: detect photos saved from other apps (Saved from Telegram)

- **Date:** 2026-11-10 · **Branch:** feat/31-saved-from-app · **Code changes:** none (probe only, not built)
- **Scope:** public and non-public attribution sources, file-level signals, filename date patterns, rule proposal, sample protocol.
- **Env:** Xcode 26.5, macOS SDK 26.5 (`MacOSX.sdk`), deployment target macOS 14 (decision 0006).

## Verdict

**No supported way exists to read "Saved from <app>" in a sandboxed app.** Apple DTS states there is no API and points to Feedback Assistant. The SDK on this machine exposes no such symbol. The database route is blocked by the sandbox and by TCC, and it is not a supported path. Ship a filename-based signal plus measurement. Do not use private API.

## 1. Public PhotoKit API (SDK 26.5 headers, Apple docs)

| Symbol | Availability | What it gives | Attribution? |
|---|---|---|---|
| `PHAsset.sourceType` (`PHAssetSourceType`) | iOS 9 / macOS 10.x+ | `UserLibrary`, `CloudShared`, `iTunesSynced`, `None` (option set) | **No.** Describes the library path, not the app. |
| `PHAsset.addedDate` | macOS 26.0+ (`API_AVAILABLE(macos(26.0))`) | Date the asset entered this library | No. Useful as a timing signal only (see R6). |
| `PHAsset.contentType` / `PHAssetResource.contentType` | macOS 26.0+ | `UTType` | No. |
| `PHAssetResource.originalFilename` | macOS 10.15+ | Filename as stored | Indirect (filename pattern only). |
| `PHAsset.location` | macOS 10.13+ | Capture location | No (Apple DTS explicitly says so). |

- `PhotosTypes.h` and `Photos.framework` headers: grep for `importedBy`, `contributor`, `bundle`, `saved`, `origin`, `provenance` returns nothing relevant. Only `PHAssetSourceType` and `PHAssetCollectionSubtypeAlbumImported` (an album subtype for imported albums, not an app) match.
- `Photos.tbd` exports include private `_PHAssetImportSourceDescription`, `PHAssetImportProperties`, `PHImportController`, `PHImportAsset`, `PHImportDeviceAsset`. None are in public headers. Do not call them.
- **Apple DTS (forum thread 760650, Aug 2024, accepted answer):** "There is no API to access the 'Saved from <app>' information. Please file an enhancement request … using Feedback Assistant." Source: [developer.apple.com/forums/thread/760650](https://developer.apple.com/forums/thread/760650).
- Apple docs for `PHAsset.sourceType` are thin in the fetched copy (title only). Confirmed by the header in the SDK.
- WWDC26 / macOS 27 PhotoKit: search found nothing. The SDK here is 26.5, so any macOS 27 addition is unverified and cannot be built against.

**Cross-check:** SDK headers (primary) + DTS answer (Apple, primary) + osxphotos author (secondary: "PhotoKit doesn't expose this"). Three independent references agree: none.

## 2. Non-public options

| Option | What exists | Sandbox | Risk | Verdict |
|---|---|---|---|---|
| Read `Photos.sqlite` (`ZADDITIONALASSETATTRIBUTES` or similar) | Unverified. The name `ZIMPORTEDBY*` from the spike brief is **not confirmed**: no source found. Photos 5+ is a Core Data store with triggers (osxphotos author). | **Blocked.** The sandboxed app has no access to the library. Terminal also cannot read it: `ls` gives *Operation not permitted*, `sqlite3 mode=ro` gives *authorization denied* (checked on this machine, schema only). | Reverse-engineered schema changes per macOS; "some of them are surely wrong" (osxphotos wiki). Writes would corrupt the library. | **Reject.** |
| KVC / undocumented PHAsset keys | Not verified on this SDK. | Works only if the key exists. | Private API: Mac App Store rejection; notarization may pass but breaks silently across macOS. | **Reject.** |
| `_PHAssetImportSourceDescription` and other private `PHImport*` symbols | Exported in `Photos.tbd`, purpose unknown. | Same. | Private SPI; crash risk. | **Reject.** |
| osxphotos | Reads the library DB outside the sandbox; no documented attribution column. | Not applicable. | Not a dependency we can ship. | **Reject.** |

- The owner's Photos Info panel shows the attribution, so the data exists in the library. Its storage is not public, and a sandboxed app cannot reach it without private API. A "Saved from SnapBridge" forum report says it shows on iOS but not on macOS (single source, unverified).

## 3. Is the attribution in the file?

Evidence is mostly secondary (vendor blogs). Treat all rows as **claimed** unless noted.

| App | Photo mode (compressed) | File/document mode | Software tag | Filename | Source / status |
|---|---|---|---|---|---|
| Telegram | EXIF/IPTC/XMP stripped (claimed) | Original kept, EXIF incl. MakerNotes (claimed) | Not addressed | Desktop export: `photo_N@DD-MM-YYYY_hh-mm-ss.jpg` (**official**). Save-to-gallery name: **not found**; issue's `telegram-cloud-photo-size-…` **unverified** | [Telegram export schema](https://core.telegram.org/import-export) (official); [fast.io](https://www.fast.io/resources/whatsapp-telegram-signal-photo-metadata-preservation.md) (vendor, claimed); Telegram bug tracker (user forum) |
| WhatsApp | Stripped GPS, camera, timestamps, IPTC/XMP; "software version" stripped (claimed) | Document mode keeps metadata ("100%", vendor claim) | Stripped in photo mode (claimed) | `IMG-YYYYMMDD-WAnnnn` / `YYYYMMDD-WA0000x` (forum, multiple users) | [fast.io](https://www.fast.io/resources/whatsapp-telegram-signal-photo-metadata-preservation.md); forum reports via search (not fetched) |
| Signal | All EXIF incl. software stripped (claimed; cites PrivacyStrip) | File attachment "may be preserved" (hedged) | Stripped (claimed) | Save-to-album: `signal-YYYY-MM-DD-HHMMSS.jpg`, `_NNN` index for multi-attachment (Signal-Desktop fork commit + GrapheneOS forum; not official) | fast.io; [Signal-Desktop fork](https://git.uninsane.org/colin/Signal-Desktop/commit/bf904ddd129ceba8fa363ccf6d10ecd256c65f63) |
| Messenger | Not verified | Not verified | Not verified | `received_…`, `FB_IMG_…`: **not confirmed** by any fetched source. Android shares rename to `orca_share_media…` (Android Central forum) | None adequate |
| Zalo | Not verified | Not verified | Not verified | Zalo PC saves to `Zalo Received Files` (folder, one blog). File naming **not found** | None adequate |
| Safari / Chrome "Save Image" | Not verified | n/a | Not verified | Not verified (expected: URL basename, unconfirmed) | None |
| Instagram | Not verified | n/a | Not verified | Not verified | None |

- **Software tag:** WhatsApp and Signal strip it in photo mode (claimed); Telegram is not addressed. It is not a dependable app marker. iPhone camera files carry an iOS version string there, so a version-like value means nothing. A text value naming an app is possible but unverified.
- **Key implication:** Photo-mode sends strip EXIF, so they already fall to rule 3 (`saved`). File-mode sends keep the camera EXIF of the original, so they go to `camera`. That is the issue's problem case. No file-level field reliably names the app in that case.
- **Photos-level save path:** When an app writes via PhotoKit, the attribution is probably set by the system at save time (inference; the Photos feature does not need EXIF). Unverified. Test: save the same image from Telegram "Save to Gallery" vs. via the share sheet, and compare Info.

## 4. Filename-encoded dates (fallback for FR-113)

| Pattern | Example | Date meaning | Confidence |
|---|---|---|---|
| Telegram Desktop export | `photo_2@29-10-2021_09-30-00.jpg` | Message date, day-first, local time | **High** (official schema). Only applies to folder/export imports. |
| Signal (desktop/Android save) | `signal-2024-05-01-101530.jpg` | Save time if saved before sending; send time if saved later | **Medium**: fork and forum sources. Date is when saved, not taken. |
| WhatsApp | `IMG-20180414-WA0033.jpg` | Receive date, not capture date | **Medium**: forum and tool sources. Use only as receive-time proxy. |
| Android Pixel / camera | `PXL_20200820_141005222.jpg`, `IMG_YYYYMMDD_HHMMSS` | Capture time in device/local clock | **Medium**: blogs and Bellingcat (2024). Bellingcat notes some files get the upload date instead. |
| Android screenshot | `Screenshot_YYYYMMDD-HHMMSS.png` | Capture time | **Low** (one blog). |
| iPhone `IMG_NNNN.HEIC` | no date | none; use EXIF | n/a |
| Messenger, FB, Zalo | see section 3 | — | **Unverified**: do not use. |

- Filename date is **not** capture date for WhatsApp, Signal, and cloud re-uploads. Prefer EXIF `DateTimeOriginal` always. Use a filename date only when EXIF is absent and the pattern matches one of the high or medium rows. Record the source as `dateSource`.
- FR-113 current fallback uses file dates, which for cloud imports are upload or modify times. A filename date beats a later file date. Keep the "earlier of created and modified" rule for the rest.

## 5. Proposed rules

Current FR-20: 1 screenshot, 2 chat album, 3 no camera Make/Model → `saved`, 4 camera.

| Order | Rule | Category | Confidence | Note |
|---|---|---|---|---|
| 1 | Screenshot subtype | `screenshot` | High | Unchanged. |
| 2 | Album exactly named like a chat app | `saved` (`chatAppAlbum`) | High precision, user-controlled | Unchanged. Zero code path for the owner. |
| 3 | **New (measure first):** Photos `originalFilename` matches a verified chat-app family (e.g. Telegram Desktop export pattern) | `saved` (`chatAppFilename`) | Low to medium. Depends on whether Photos keeps the name. | Adopt only if the sample shows the pattern on Photos assets. |
| 4 | Photo with no TIFF Make/Model and no RAW | `saved` (`missingCameraExif`) | Medium. Catches photo-mode sends and scans. Keep. | Unchanged. |
| 5 | **Candidate (measure only):** `addedDate − creationDate` large (days) and photo is not from a camera-linked album | `saved` (`addedLongAfterCapture`) | Low. False positives from late iCloud sync of iPhone photos. | Needs a measured threshold. Requires macOS 26 (`#available` guard; deployment target 14). |
| — | Software tag names a chat app | — | Low, unverified | **Do not add.** No evidence of the value. |
| — | Source app from Photos | — | None available | **Do not add** until an API exists. |

- **CategoryReason:** add `chatAppFilename` only if rule 3 is adopted; `addedLongAfterCapture` only if rule 5 is adopted. Do not add `savedFromAppAttribution`.
- **Sidecar:** no new field now (YAGNI). If a source appears, add `savedFromApp` to `sidecar-schema.md`. Logs stay free of names (FR-123).
- **Spec edits:** FR-20 table, FR-113 date order, and the filename-date line. README known-limits: "Saved from" not readable; scans may land in `saved`.

### Reclassification risk

- FR-20 already says a rule change applies only to assets not yet placed (spec line 148). Placed photos do not move by rule change alone. Keep that.
- Any backfill is a separate, explicit action. Before enabling: dry-run count of transitions `(old → new, reason)` on the owner's library, with no writes. Cap moves per run.
- Measurement: run the probe (section 6) on a 200-asset sample, then the dry-run on the full library. Stop if camera → saved moves exceed a few percent of the camera set.

## 6. Sample-collection protocol (owner)

**Samples** (save each in both modes where the app offers them):
- Telegram: Save Image (chat photo), Save to Photos from the menu; send as File, then save.
- WhatsApp: received image saved; document-mode image saved.
- Signal: attachment Save.
- Messenger, Zalo, Safari "Save Image" (one each, if installed).
- Controls: 10 iPhone camera photos, 5 screenshots, 3 scans (Notes or Files), 3 Mac-saved downloads.
- Aim: at least 5 per app/mode cell. Two shots are not enough.

**Per sample, the owner records (counts only, outside the repo):**
- app, mode (image or file), date saved;
- what Photos Info shows under "Saved from" (ground truth; the owner types the app name only into their own notes);
- what PhotoVault's probe prints (below).

**Probe output** (`probe/SavedFromProbe.swift`, read-only, local bytes only, no file names or Software text printed):
- `photoShape`: file-name shape (digits → 9, letters → A/a).
- `make`, `model`, `software` (absent / version-like / text), `userComment` presence.
- `daysAddedMinusCreated`: `addedDate − creationDate` (macOS 26+).
- `mediaSubtypes`, resource count.
- Summary by family `shape | make | model | software` with counts.

Run: `swiftc -O SavedFromProbe.swift -o /tmp/saved_from_probe && /tmp/saved_from_probe 200` (owner's Terminal needs Photos access). **Not run yet**: typecheck only (`swiftc -typecheck`, passed).

**Accuracy target to call the rule shipped:** for each app/mode cell, the rule's `saved` decision matches Photos Info in ≥ 80% of samples, and no camera control goes to `saved`.

## Trade-off ranking

| Rank | Option | Accuracy | Complexity | Maintenance | Risk | Sandbox fit | Recommendation |
|---|---|---|---|---|---|---|---|
| 1 | Keep public heuristics; add filename rule (R3) only if measured; file Feedback Assistant request | Low–medium for app-saved camera-EXIF photos | Low | Low | Low | Full | **Adopt** |
| 2 | Owner manual or album routine (existing rule 2) | High for what the owner files | None code | Owner effort | None | Full | Use now as the workaround |
| 3 | Read Photos DB or private symbols | High if it works | High | High (breaks per OS) | High (MAS rejection, corruption) | **None** | Reject |

- **Adoption risk for R3:** filename patterns are unversioned and chat apps may change them. Keep it behind a setting or a reason code so it can be turned off.
- **Architectural fit:** matches FR-20's rule order and CategoryReason design. Adds no entitlements. Keeps the sandbox clean.

## Limitations

- No live Photos library or owner sample. The probe was typechecked, not run. Rules 3 and 5 are unmeasured.
- Messenger, Zalo, Safari, Instagram naming and EXIF are **unverified**. Only secondary and vendor sources were used. Telegram's save-to-gallery name is unknown.
- Did not check macOS 27 SDK (not on this machine; WWDC26 search empty).
- Did not test Photos attribution sync via iCloud to other Macs.
- Did not verify whether `PHAssetResource.originalFilename` survives a save from another app; that is the key open test.

## Unresolved questions

1. Does `PHAssetResource.originalFilename` keep the sender's name (Telegram, WhatsApp) for Photos assets? Answered only by the owner's sample.
2. Does a file-mode send keep the camera EXIF through Telegram "Save to Gallery"? Measured by the probe.
3. Is the attribution in the library synced to iCloud and other Macs? Untested.
4. Should the owner file the Feedback Assistant request now? Recommended, low cost; owner decision.
5. What is `_PHAssetImportSourceDescription`? Private; not to be called. Keep it out of code.
6. Threshold for R5 (`addedLongAfterCapture`) needs owner data.
7. Should PhotoVault ship a setting to turn off filename rules (R3)? Owner decision.
