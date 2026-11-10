# Sidecar schema

Sidecars are the `<stem>.json` and `<stem>.xmp` files written next to each backed-up asset (spec FR-90 to FR-93). This page describes what the code writes today. The source is `Sources/PhotoVaultCore/Policies/SidecarBuilder.swift`, `SidecarJSON.swift`, `SidecarXMP.swift` and `SidecarInput.swift`.

Checked against the code on 2026-11-09. The examples below were produced by running `SidecarBuilder.buildJSON` and `buildXMP` on the input described in [Examples](#examples).

**Engine wiring (as of this check):** `SidecarFactory.build` in `Sources/PhotoVaultEngine/SidecarPlanner.swift` builds the input from the database and calls `buildJSON` or `buildXMP`. For an asset imported from a folder it also passes the [`source`](#source) block. It passes no extended metadata, so the JSON carries `"extendedMetadata": "unavailable"`. `SidecarPlanner` writes the first sidecar only after every original job of the asset at that destination has finished (`done` or `skipped`), as spec FR-93 requires.

## Files

| File | Content | Notes |
|---|---|---|
| `<stem>.json` | JSON object, described below | `stem` is the asset's `name_stem` (spec FR-41), so the sidecar sits beside the backup files |
| `<stem>.xmp` | XMP packet, described below | digiKam and Lightroom look for different names; see [README known limits](../README.md#known-limits) |

A RAW+JPEG pair shares one `.json` and one `.xmp` (spec §8.12). The sidecar content differs per destination (FR-90). The JSON `resources` list covers that destination's files only.

`SidecarFile` computes the SHA-256 and MD5 of the bytes in memory. The engine stores as `uploaded_hash` the MD5 for Google Drive and the SHA-256 for local folders (`SidecarFactory.hash`). That is the hash each destination reports back. A sidecar is uploaded again only when its hash changes (FR-93). After a database loss, recovery reads back the JSON sidecars it finds (local files, or one small Drive download each) and puts back the resource hashes and camera fields they list. A sidecar is not refreshed while its place name is still being looked up. So recovery writes a sidecar again only when its content really differs, or when it cannot be read back (then once).

## JSON fields

Types: `string`, `number` (integer or fixed-decimal), `bool`, `array`, `object`. "When" says when the key appears; otherwise it is always present.

### Top level

| Key | Type | When | Source | Format |
|---|---|---|---|---|
| `schemaVersion` | number | always | `SidecarInput.schemaVersion`, `1` | integer |
| `assetKey` | string | always | `asset.assetKey` | `c:<cloudId>` or `l:<localId>`; `x:<sha256>` for a file imported from a folder |
| `localIdentifier` | string | always | `asset.localId` | PhotoKit local identifier; for an imported file `<sourceId>/<relative path of the primary file>` |
| `cloudIdentifier` | string | `asset.cloudId` is set | `asset.cloudId` | PhotoKit cloud identifier |
| `creationDate` | string | `asset.creationDate` is set | UTC | `yyyy-MM-ddTHH:mm:ss.SSSZ` |
| `archiveLocalDateTime` | string | `creationDate` is set | archive timezone | `yyyy-MM-ddTHH:mm:ss`, no offset |
| `archiveTimezone` | string | always | `archiveTimeZone.identifier` | IANA id, for example `Asia/Ho_Chi_Minh` |
| `modificationDate` | string | `asset.modificationDate` is set | UTC | as `creationDate` |
| `mediaType` | string | always | `asset.mediaType` | `unknown`, `image`, `video` or `audio` |
| `mediaSubtypes` | array of string | always (may be empty) | `asset.mediaSubtypes` | in this order: `panorama`, `hdr`, `screenshot`, `live`, `depthEffect`, `spatial`, `streamed`, `highFrameRate`, `timelapse`, `screenRecording`, `cinematic` |
| `pixelWidth` | number | always | `asset.pixelWidth` | integer |
| `pixelHeight` | number | always | `asset.pixelHeight` | integer |
| `duration` | number | always | `asset.duration` | 3 decimals; `0.000` for photos; non-finite becomes `0` |
| `isFavorite` | bool | always | `asset.isFavorite` | |
| `isHidden` | bool | always | `asset.isHidden` | |
| `category` | string | `asset.category` is set | `asset.category` | `camera`, `screenshot` or `saved` |
| `categoryReason` | string | `asset.categoryReason` is set | `asset.categoryReason` | `screenshotSubtype`, `chatAppAlbum`, `missingCameraExif`, `cameraDefault` or `pendingHeaderRead` |
| `burstIdentifier` | string | `asset.burstIdentifier` is set | `asset.burstIdentifier` | |
| `location` | object | `asset.location` is set | `asset.location` | `{ "latitude": number, "longitude": number }`, 6 decimals. **Exact coordinates, not rounded.** |
| `place` | object | `SidecarInput.place` is set | geocode of the asset's cell | see below |
| `source` | object | the asset was imported from a folder or a cloud folder (`SidecarInput.source` is set) | the import | see [`source`](#source); absent for Photos assets |
| `camera` | object | at least one camera field is set | asset and device name | see below |
| `albums` | array of string | always (may be empty) | `SidecarInput.albumTitles` | sorted by UTF-8 bytes, duplicates removed |
| `resources` | array of object | always (may be empty) | `SidecarInput.resources` | see below |
| `caption` | string | `extendedMetadata` is present and its `caption` is not nil | `PHAssetExtendedMetadata` (macOS 27+) | an empty string is kept |
| `keywords` | array of string | `extendedMetadata` is present | `PHAssetExtendedMetadata` (macOS 27+) | sorted by UTF-8 bytes; **not** de-duplicated |
| `extendedMetadata` | string | `extendedMetadata` is nil | constant | always `"unavailable"` on the current SDK ([0006](decisions/0006-macos-27-apis-unavailable.md)) |

### `place`

| Key | Type | When |
|---|---|---|
| `isoCountryCode` | string | the geocode has it |
| `country` | string | the geocode has it |
| `administrativeArea` | string | the geocode has it |
| `locality` | string | the geocode has it |

Each key is omitted when nil. The object can be empty if every field is nil.

### `source`

Written only for assets imported from a folder on this Mac, Google Drive or Dropbox (`ImportIngest`, `SidecarFactory.sourceBlock`, which writes the source kind's raw value). A Photos asset's sidecar has no `source` key, so its bytes did not change when sources were added (the schema stays at version 1 because the key is optional).

| Key | Type | When | Source |
|---|---|---|---|
| `kind` | string | always | the source kind: `localFolder`, `googleDrive` or `dropbox` (`SourceKind` raw values) |
| `name` | string | always | a name that does not depend on the app language: the folder's name for a Mac folder, a single picked Drive folder or a Dropbox folder; otherwise the provider (`Google Drive` for several picks, `Dropbox` for the whole account). It is `SourceConfig.sidecarName`, and the import's display name when that is unset |
| `path` | string | always | path of the primary file inside the imported folder, NFC. For a Google Drive pick it is inside the picked folder, or the file's name when a file was picked. For Dropbox it is relative to the chosen folder (or the account root). |
| `dateSource` | string | the primary's import row has it | `exif`, `video` or `fileDate`: which rule gave the creation date |

Example (keys sorted like the rest of the file):

```json
  "source": {
    "dateSource": "exif",
    "kind": "localFolder",
    "name": "Da Lat trip",
    "path": "day2/DSC01234.ARW"
  },
```

### `camera`

| Key | Type | Source |
|---|---|---|
| `make` | string | `asset.cameraMake` |
| `model` | string | `asset.cameraModel` |
| `deviceName` | string | `SidecarInput.deviceDisplayName`, from the device table |
| `lens` | string | `asset.lensModel` |

The object is omitted when all four are nil.

### `resources[]`

One object per file of this asset at this destination, sorted by the numeric resource type, then by `backupName`.

| Key | Type | When | Values |
|---|---|---|---|
| `type` | string | always | `ResourceType` name: `photo`, `video`, `audio`, `alternatePhoto`, `fullSizePhoto`, `fullSizeVideo`, `adjustmentData`, `adjustmentBasePhoto`, `pairedVideo`, `fullSizePairedVideo`, `adjustmentBasePairedVideo`, `adjustmentBaseVideo`, `photoProxy`, `sidecarJson`, `sidecarXmp`, or `unknown<N>` |
| `kind` | string | always | `original`, `edited`, `sidecarJson`, `sidecarXmp` |
| `originalName` | string | always | filename from PhotoKit |
| `backupName` | string | always | name at the destination (FR-41) |
| `state` | string | always | job state: `pending`, `uploading`, `done`, `deferred`, `skipped`, `cancelled` or `missingRemote` |
| `size` | number | known | bytes, integer |
| `md5` | string | known | 32 hex characters |
| `sha256` | string | known | 64 hex characters |

## XMP mapping

The XMP packet carries only what the original file does not have (FR-92). It never contains dates, GPS or EXIF.

| XMP property | Written when | Value |
|---|---|---|
| `xmp:Rating` | `isFavorite` is true | `5` |
| `dc:description` (`rdf:Alt`, `xml:lang="x-default"`) | caption is non-empty | the caption |
| `dc:subject` (`rdf:Bag`) | at least one keyword is non-empty after escaping | keywords, sorted and unique |
| `lr:hierarchicalSubject` (`rdf:Bag`) | an album title is non-empty, or `category` is set | `PhotoVault\|Album\|<title>` for each album (sorted, unique, `\|` in a title becomes `/`), then `PhotoVault\|Category\|<category>` |
| `photoshop:City` | `place.locality` is non-empty | locality |
| `photoshop:State` | `place.administrativeArea` is non-empty | administrative area |
| `photoshop:Country` | `place.country` is non-empty | country |

Escaping: characters that are not allowed in XML 1.0 are removed (control characters other than tab, line feed and carriage return; U+FFFE and U+FFFF; U+007F to U+009F), and so are Unicode format characters (category `Cf`, for example bidi overrides and zero-width spaces). The five markup characters `& < > " '` are escaped.

Packet: `<?xpacket begin="…" id="W5M0MpCehiHzreSzNTczkc9d"?>`, `x:xmpmeta` with `x:xmptk="PhotoVault"`, and an `rdf:Description` that declares the `xmp`, `dc`, `lr` and `photoshop` namespaces.

## Determinism

The same `SidecarInput` gives the same bytes. The tests check this (`SidecarBuilderTests`). The rules that make it so:

1. No generation time, random value or locale is written. Dates use a fixed `en_US_POSIX` formatter.
2. JSON keys are sorted by UTF-8 bytes. Indentation is two spaces. The file ends with one newline.
3. JSON strings escape `"`, `\`, line feed, carriage return, tab, other control characters, U+2028 and U+2029. Non-ASCII text (Vietnamese) is written as UTF-8.
4. Numbers: integers as-is; `duration` with 3 decimals; `latitude` and `longitude` with 6 decimals; NaN, infinity and negative zero become `0`.
5. `albums` is de-duplicated and sorted in JSON. XMP sorts and de-duplicates `albums` and `keywords`. JSON `keywords` is sorted only.
6. `resources` are sorted by the numeric type, then `backupName`.
7. `mediaSubtypes` follow the fixed table order above, not alphabetical order.
8. XMP uses the same sorted, de-duplicated album and keyword lists whatever the input order.

## Examples

The examples come from this input (sample values, not a real asset):

| Field | Value |
|---|---|
| Asset key | `c:6D2B1E0A-5C7F-4B8E-9A11-3F2E8D7C6B5A` |
| Created | 2026-11-08 02:14:03 UTC (09:14:03 in `Asia/Ho_Chi_Minh`) |
| Modified | 2026-11-08 03:40:11 UTC |
| Type | image, camera, favourite, no subtypes |
| Camera | SONY ILCE-7M4, lens `FE 24-70mm F2.8 GM II`, device name `Sony A7 IV` |
| Location | 11.940412, 108.458312 |
| Place | VN, Vietnam, Lâm Đồng, Đà Lạt (names follow `PlaceNameRule` without the native name in parentheses: decision 0023) |
| Albums | `Đà Lạt 2026`, `Family` |
| Resources | original `DSC01234.ARW` (done, with size, md5 and sha256); edited `FullSizeRender.JPG` as `(edited).JPG` (pending) |
| Extended metadata | none (current SDK) |

The hashes in the resource entries are placeholders. The edited resource has no size or hashes because it has not been uploaded yet.

### JSON

```json
{
  "albums": [
    "Family",
    "Đà Lạt 2026"
  ],
  "archiveLocalDateTime": "2026-11-08T09:14:03",
  "archiveTimezone": "Asia/Ho_Chi_Minh",
  "assetKey": "c:6D2B1E0A-5C7F-4B8E-9A11-3F2E8D7C6B5A",
  "camera": {
    "deviceName": "Sony A7 IV",
    "lens": "FE 24-70mm F2.8 GM II",
    "make": "SONY",
    "model": "ILCE-7M4"
  },
  "category": "camera",
  "categoryReason": "cameraDefault",
  "cloudIdentifier": "6D2B1E0A-5C7F-4B8E-9A11-3F2E8D7C6B5A",
  "creationDate": "2026-11-08T02:14:03.000Z",
  "duration": 0.000,
  "extendedMetadata": "unavailable",
  "isFavorite": true,
  "isHidden": false,
  "localIdentifier": "7F0E2B1A-3C4D-4E5F-8A9B-0C1D2E3F4A5B/L0/001",
  "location": {
    "latitude": 11.940412,
    "longitude": 108.458312
  },
  "mediaSubtypes": [],
  "mediaType": "image",
  "modificationDate": "2026-11-08T03:40:11.000Z",
  "pixelHeight": 4000,
  "pixelWidth": 6000,
  "place": {
    "administrativeArea": "Lâm Đồng",
    "country": "Vietnam",
    "isoCountryCode": "VN",
    "locality": "Đà Lạt"
  },
  "resources": [
    {
      "backupName": "2026-11-08 09.14.03_DSC01234.ARW",
      "kind": "original",
      "md5": "0123456789abcdef0123456789abcdef",
      "originalName": "DSC01234.ARW",
      "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "size": 52428800,
      "state": "done",
      "type": "photo"
    },
    {
      "backupName": "2026-11-08 09.14.03_DSC01234 (edited).JPG",
      "kind": "edited",
      "originalName": "FullSizeRender.JPG",
      "state": "pending",
      "type": "fullSizePhoto"
    }
  ],
  "schemaVersion": 1
}
```

### XMP

```xml
<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="PhotoVault">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
    xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
   <xmp:Rating>5</xmp:Rating>
   <lr:hierarchicalSubject>
    <rdf:Bag>
     <rdf:li>PhotoVault|Album|Family</rdf:li>
     <rdf:li>PhotoVault|Album|Đà Lạt 2026</rdf:li>
     <rdf:li>PhotoVault|Category|camera</rdf:li>
    </rdf:Bag>
   </lr:hierarchicalSubject>
   <photoshop:City>Đà Lạt</photoshop:City>
   <photoshop:State>Lâm Đồng</photoshop:State>
   <photoshop:Country>Vietnam</photoshop:Country>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>
```

The first line begins with a byte-order mark (U+FEFF) inside the `xpacket` processing instruction, as the builder writes it.

## Known gaps in the schema

- The JSON has no file path, Drive ID, or other destination's hashes. That is intentional.
- The asset's size is not written at the top level. Only each resource's `size` is written, and only when known.
- Captions and keywords appear only on macOS 27 builds that have the extended-metadata API. Current builds write `"extendedMetadata": "unavailable"`.
- The builder has no tests that parse the example files with exiftool. Spec FR-92 requires that XMP be readable by exiftool (spec FR-92, "Phải đọc được bằng exiftool"). That check is for the owner's M0 or a later test.
