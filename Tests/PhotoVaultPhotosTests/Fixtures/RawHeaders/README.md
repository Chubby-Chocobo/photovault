# RAW header fixtures

These are the opening bytes of real RAW files, enough to hold the TIFF or maker directories with the camera make and model. They come from [raw.pixls.us](https://raw.pixls.us/), whose contributors release their files into the public domain (CC0). `manifest.json` lists each prefix with its source and the camera that exiftool reads from the complete file.

Each prefix is the smallest one from which `HeaderClassifier` finds the camera when given the resource's UTI (measured on macOS 26.6), rounded up with at least 48 KiB to spare. `RawHeaderFixtureTests` feeds a prefix as one PhotoKit chunk. It fails if the camera is no longer found from these bytes, for example because the UTI hint was dropped or the classifier needs more data.

To add a format, take its prefix from the full corpus (`../MediaCorpus/`) and add an entry to `manifest.json`.
