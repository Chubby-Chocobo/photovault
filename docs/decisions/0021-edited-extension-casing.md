# 0021 File extensions: originals keep their case; edited and derived names use an upper-case UTI extension

- **Status:** Accepted
- **Spec refs:** FR-41 (`… (edited).HEIC`, original extension kept, edited extension from the UTI), §8.4
- **Review trigger:** when the owner prefers another extension for edited files

## Context

FR-41 says an edited file takes its extension from the UTI and does not use `FullSizeRender`. The spec example is `2026-11-08 14.03.22_IMG_4821 (edited).HEIC`. It does not say how the UTI extension is cased.

## Decision

`NameStemBuilder` (`Rules/NameStemBuilder.swift`):

- **Original:** the extension comes from the primary resource's filename and keeps its case (`.ARW`, `.mov`). If the filename has none, the UTI extension is used.
- **Edited:** `utiExtension(uti)` is `UTType(uti)?.preferredFilenameExtension` upper-cased, with `bin` when the UTI is unknown. The suffix is ` (edited)`.
- **Sidecars:** `.json` and `.xmp`, lower case, with no suffix.

Verified with `UniformTypeIdentifiers` on the build toolchain:

| UTI | Preferred extension | Name suffix used |
|---|---|---|
| `public.heic` | `heic` | `(edited).HEIC` |
| `public.jpeg` | `jpeg` | `(edited).JPG` (mapped) |
| `com.apple.quicktime-movie` | `mov` | `(edited).MOV` |
| `public.mpeg-4` | `mp4` | `(edited).MP4` |

## Consequences

- A JPEG edit is named `(edited).JPG`: `NameStemBuilder.utiExtension` maps `JPEG` to `JPG` to match the iPhone and camera naming.
- Because the edited extension is upper-cased, the name does not match the sidecar's lower-case `.json` and `.xmp`. That is intended: the sidecars are generated, not exported by Photos.
- The sidecar schema example in [sidecar-schema.md](../sidecar-schema.md) uses the same mapping.
