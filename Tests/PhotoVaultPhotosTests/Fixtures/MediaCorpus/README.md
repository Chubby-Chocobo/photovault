# Media corpus

These are complete RAW files that are too large for git. `manifest.json` gives each file's source URL (raw.pixls.us, public domain), its SHA-256 and the behaviour the app must keep:

- `isRaw`: what `UTTypeResolver` says about the file's UTI; a RAW is a camera photo from scan time;
- `make` and `model`: the camera the export step stores (exiftool's values, trimmed). It must be named also on a macOS whose ImageIO does not know the camera;
- `fallback: false`: the file's own fallback (`RawCameraFallback`) cannot name the camera, so only ImageIO does;
- `noCaptureDate`: the format carries no capture date. For every other camera file, a missing date means the reader lost the file's type;
- `unsupported`: macOS cannot read the format at all.

Fetch the files with:

```sh
python3 -I scripts/fetch-media-corpus.py ~/media-corpus
PHOTOVAULT_MEDIA_CORPUS=~/media-corpus swift test --filter MediaCorpusTests
```

The tests are skipped when `PHOTOVAULT_MEDIA_CORPUS` is unset. When it is set, every file must be present and match its checksum.

CI saves the cache right after the fetch, keyed by the manifest's hash. When only the expectations changed, CI restores the previous corpus, so nothing is downloaded again. It runs these tests on every build. The download script has a timeout and tries each file up to three times. If raw.pixls.us ever drops a file, mirror it elsewhere and change its `url`; the checksum stays.
