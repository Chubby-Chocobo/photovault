# Media corpus

These are complete RAW files that are too large for git. `manifest.json` gives each file's source URL (raw.pixls.us, public domain), its SHA-256 and the behaviour the app must keep:

- `isRaw`: what `UTTypeResolver` says about the file's UTI;
- `make` and `model`: the camera the app reads (exiftool's values, except where a `note` explains an ImageIO gap);
- `maxHeaderBytes`: the most bytes the header classifier may consume, in 1 MiB PhotoKit chunks, before it names the camera;
- `fromCompleteFile`: the camera is read from the complete file after the classifier's buffer fills;
- `unsupported`: macOS cannot read the format at all.

Fetch the files with:

```sh
python3 -I scripts/fetch-media-corpus.py ~/media-corpus
PHOTOVAULT_MEDIA_CORPUS=~/media-corpus swift test --filter MediaCorpusTests
```

The tests are skipped when `PHOTOVAULT_MEDIA_CORPUS` is unset. When it is set, every file must be present and match its checksum. CI caches the corpus under the manifest's hash and runs these tests on every build.
