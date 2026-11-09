# RAW header fixtures

These are the opening bytes of real RAW files, enough to hold the directories with the camera make and model. They come from [raw.pixls.us](https://raw.pixls.us/), whose contributors release their files into the public domain (CC0). Each prefix is a byte-for-byte copy of the start of the matching corpus file (`../MediaCorpus/`).

`manifest.json` lists each prefix with its source and the camera exiftool reads from the complete file, trimmed:

- `imageIOLacksMake`: ImageIO reports only the model (Samsung SRW); the reader takes the make from the file itself;
- `fallback: false`: the file's own fallback cannot name the camera (Minolta MRW).

Each prefix is the smallest one from which `HeaderClassifier` finds the camera when given the resource's UTI (measured on macOS 26.6), rounded up with at least 48 KiB to spare. `RawHeaderFixtureTests` checks that:

- the file counts as RAW, so it is a camera photo from scan time;
- ImageIO names the camera from the prefix as one PhotoKit chunk;
- `RawCameraFallback` names it without ImageIO;
- the folder and the manifest list the same files.

To add a format, take its prefix from the corpus file and add an entry to `manifest.json`.
