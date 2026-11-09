# PR #4 review: RAW header fixtures and media corpus

Scope: `git diff origin/release/0.1.0...HEAD` on `fix/spike-raw-formats` (6 commits, 34 files, +814/-4). Read-only review.

## Verification run

- `swift test --scratch-path .build-review4` (clean dir): 821 tests in 137 suites passed, exit 0. `MediaCorpusTests` skipped; `RawHeaderFixtureTests` ran its 21 cases.
- `PHOTOVAULT_MEDIA_CORPUS=$PWD/.media-corpus swift test --scratch-path .build-review4`: 821 tests passed, exit 0. Header and staged-file tests each ran 27 cases (macOS 26.6).
- PR CI run 42570303573 (`macos-15-arm64`) **failed**: `fujifilm-raf` returned no make or model in both corpus tests (3 issues). It also hit an unrelated flake in `StagingClaimTests.swift:39`. The cache post step was **skipped**.
- All 21 committed prefixes are byte-identical to the start of the matching corpus files.
- Mutation probes on a scratch copy, run with the corpus:

| Mutation | Result |
|---|---|
| Classifier hint dropped (`HeaderClassifier.swift:46`, `uti: nil`) | caught: 6 fixture and 6 corpus failures |
| Staged-file reader hint dropped (`ImageIOMetadataReader.swift:32`) | caught: 11 corpus failures (fixture tier blind, as designed) |
| `parseStride` default raised to 1 MiB ("needs more bytes") | caught: all 21 fixtures fail; corpus still green |
| `isRaw` excludes DNG | caught: 8 failures |
| `maxBuffered` default raised to 512 MiB (overflow effectively disabled) | **not caught**: all green |

- An empty or undecodable manifest is caught: `try?` gives `[]`, and the count guards then fail.

## Findings

### Critical

1. **CI is red on the PR: the expectations were measured on macOS 26 and fail on the `macos-15` runner.**
   - Where: `.github/workflows/ci.yml:22` with `Fixtures/MediaCorpus/manifest.json:118` (`fujifilm-raf`). The README files and the spike doc say the values come from macOS 26.6.
   - Failure: macOS 15 ImageIO returns no properties for the X-T30 III RAF. `MediaCorpusTests.swift:86` and `:100-101` fail on every run.
   - Impact once merged: every PR and every release `workflow_call` verify turns red. Because of finding 2, every run also re-downloads the whole corpus.
   - Real behaviour, not test noise: on macOS 15 the app classifies these RAFs as having no camera. The manifest needs to encode that per OS rather than hide it.
   - Fix, either way:
     - run on a macOS 26 runner image and state the OS the expectations hold for; or
     - add an OS-gated expectation (for example `"minOS": "26.0"` or per-OS make/model). Below that version, assert the older result, or wrap it in `withKnownIssue`.

### Important

2. **The corpus cache is never saved when any test fails.**
   - Where: `ci.yml:51-55`.
   - Cause: at the pinned SHA `55cc834…` (verified as v6.1.0), `actions/cache` declares `post-if: success()`. Run 42570303573 shows "Post Restore media corpus: skipped".
   - Failure: until one fully green run happens on a given branch scope, each run pulls about 767 MB from raw.pixls.us. Finding 1 guarantees that today. This also applies to any later unrelated flake, such as the `StagingClaimTests` one seen in the same run.
   - Fix: split into `actions/cache/restore` before the fetch and `actions/cache/save` right after a successful fetch, both pinned to the same SHA. Save the key only on a restore miss.

3. **A volunteer host is a hard, unbounded dependency of every cache-miss CI run.**
   - No timeout or retry: `scripts/fetch-media-corpus.py:37` calls `urlretrieve` with no socket timeout and no retry. A stalled connection hangs until the 60-minute job timeout. An outage fails CI for PRs that do not touch RAW, and fails the release verify job.
   - Cache key: `ci.yml:55` hashes the whole manifest, expectations included. Editing a make string, which code-standards.md now tells authors to do when macOS changes, invalidates all 767 MB. There is no `restore-keys`.
   - Fix:
     - `urllib.request.urlopen(url, timeout=60)` with 2–3 retries, streamed to `.part`;
     - `restore-keys: media-corpus-`, so the script only fetches the delta;
     - optionally, key on a hash of the `url`+`sha256` pairs only.

4. **The corpus loop is a copy of production, so the production call sites stay unguarded.**
   - Where: `MediaCorpusTests.swift:62-71` reimplements `PhotoKitSource+Export.swift:27-75`. No test calls `readClassificationHeader`.
   - Regressions that stay green:
     - `HeaderClassifierBox(typeHint: nil)` at `PhotoKitSource+Export.swift:38`;
     - `imageMetadata(of: file.url, uti: nil)`, or deleting the overflow branch, at `:65-68`;
     - breaking the `stoppedEarly` handling at `:54-61`;
     - passing `nil` or an empty UTI at `ExportWorker.swift:200`.
   - Result: the PR's headline claim ("regression protection for the UTI hint") holds for `HeaderClassifier`/`ImageIOMetadataReader` internals only.
   - Smaller divergences:
     - The test gets its UTI from `UTType(filenameExtension:)`; production uses `PHAssetResource.uniformTypeIdentifier`.
     - The test uses `HeaderClassifier`, not `HeaderClassifierBox`.
   - Fix: extract the chunk-driving decision into a pure function in `PhotoVaultPhotos`, for example `HeaderClassifierBox.result(afterStreamCompleted:completeFile:uti:)`. `readClassificationHeader` and the test would both call it. At minimum, state the gap in the README and spike doc instead of implying end-to-end coverage.

### Suggestion

5. **`fromCompleteFile` is a phantom expectation.**
   - Where: `MediaCorpusTests.swift:72-79` asserts only "overflowed ⇒ fromCompleteFile", never the converse. `maxHeaderBytes` is checked only for `.present` outcomes (`:89-91`).
   - Probe: raising the 32 MiB cap made `phaseone-iiq` buffer all 69 MB in memory, and the suite stayed green.
   - Fix: when `fromCompleteFile == true`, `#expect(classifier.overflowed)`.

6. **The CR3 and CRW budgets are tautological.**
   - Where: `manifest.json:55`, `:70`, `:85` set `maxHeaderBytes` equal to the file size.
   - Why it is empty: `consumed <= data.count` always holds, so the check can never fail. A CR3 that started needing `finish()` for a different reason passes the same way.
   - Fix: encode the intent, for example `"concludesOnFinish": true`, and assert that the outcome was `.needMore` before `finish()`.

7. **Manifest failures are opaque, and the count guards allow silent shrinkage.**
   - Where: `RawHeaderFixtureTests.swift:17-21` and `MediaCorpusTests.swift:32-36` use `try?`.
   - Opaque: a typo in one entry yields only `0 >= 20`, with the `DecodingError` discarded.
   - Shrinkage: `>= 20` and `>= 25` let 1–2 entries be deleted unnoticed.
   - Fix: decode with `try` inside `theManifestLists…` so the error surfaces. Assert that every non-manifest file in `Fixtures/RawHeaders/` has an entry, or pin the exact count.

8. **The docs do not match the committed corpus.**
   - `docs/spikes/m0-5-exif-and-header-classification.md` names different samples:

     | Line | Doc says | Corpus has |
     |---|---|---|
     | 82 | ILCE-7RM5 | ILCE-6400 and 7M4 |
     | 90 | 5D Mark IV | EOS 100D |
     | 98 | IIQ 109 MB | 69 MB |
     | 89 | CR3 R6 III, 35 MB, the only CR3 over 32 MiB | not in the corpus at all |

   - `docs/test-report.md:31`: "821 tests … passed" is identical with the corpus skipped, so it does not show the corpus ran. Quote the `MediaCorpusTests … 27 test cases passed` lines instead.
   - `Fixtures/RawHeaders/README.md:3` says the values are exiftool's. They are ImageIO's trimmed values (SRW make null; 3FR leading space removed).

No issues found in these areas:
- Swift 6 strictness: 0 warnings under `strictSwift`.
- Naming: PascalCase files, no plan IDs or finding codes in code or comments.
- Licensing: raw.pixls.us uploads are CC0.
- Repo size: 3.4 MB, acceptable.
- `.gitignore`: `.media-corpus/` is ignored.
- Action pinning: the full SHA matches the v6.1.0 tag.
- Fetch script:
  - It verifies the checksum before `os.replace`, follows redirects and exits non-zero on failure.
  - It is `-I`-safe (stdlib only).
  - A `.part` left after an exception is harmless: it is overwritten on the next run and never cached, because the job fails.
- Job time: 3m09s including the download.

## Verdict

1 Critical and 3 Important remain. Do not merge until finding 1 is fixed (CI green) and findings 2 and 3 are addressed. Finding 4 can be fixed or explicitly documented as a known gap.

## Unresolved questions

- Is a `macos-26` hosted runner image available to this private repo? That decides between moving the runner and gating expectations per OS.
- `StagingClaimTests.aClaimTakenWhileTheReleaseWaitsForTheDatabaseIsRefusedOrKeepsTheFile` failed on CI. It is outside this PR's scope, but it makes finding 2 worse. Is it tracked?

Status: DONE_WITH_CONCERNS
Summary: Tests catch hint, stride and isRaw regressions inside the classifier and reader, but the PR's CI is red on macos-15 because of OS-dependent RAF expectations, the cache is never saved on failure, and production call sites remain untested.
