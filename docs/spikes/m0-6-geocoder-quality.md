# M0-6: Geocoder quality, throttling and key stability

- **Status:** pending owner run
- **Spec refs:** FR-80 to FR-84, FR-106, §8.11, [VERIFY M0-6] at FR-84, §10 (M0-6)
- **Owner time:** 1–2 hours. **Wall time:** about 1 day, because the key-stability check repeats after 24 hours.

## Goal

Check that `CLGeocoder` returns the structured fields that place names need (ISO country code and administrative area in English, locality), how fast it throttles, how good the Vietnamese names are, and whether the English key stays stable over a day.

## Why it matters

Place names and the "By place" view are keyed on `isoCountryCode` and `administrativeArea` in English (FR-81, FR-106). If the fields are missing, FR-84 says to fall back to the country only. The engine's `GeocodeScheduler` does that after three results in a row with a country but no province. The throttle decides whether the 20-per-minute limit in `GeocodeScheduler` is right.

## Preconditions

- The probe from [the shared setup](README.md#probe-setup-shared).
- Twenty real coordinates from the owner's library, chosen to cover: Đà Lạt, Hà Nội, Hội An or Huế; one place in Japan or another foreign country; one point on the sea or a lake; one point near a border; one point with no area name expected.
- Network access. The geocoder is Apple's service.

## Procedure

1. For each of the 20 coordinates, compute its cell (`GeoCell(GeoPoint(...))`) and its centre (`GeoCell.center`). Call `CLGeocoderReverseGeocoder().reverseGeocode(cell:locale:)` with `en` and with `vi`. Record `isoCountryCode`, `administrativeArea`, `locality` and `country` for both.
2. Note any cell where `isoCountryCode` or `administrativeArea` is missing in `en`.
3. Throttle test: send 60 requests, one per 3 seconds (20 per minute). Record any error. Then send 60 requests with no pause. Record the first error, its `CLError` code, and how many succeed before it.
4. Quality review: for each `vi` result in Vietnam, note whether the locality and province names read correctly in Vietnamese.
5. Key stability: 24 hours later, repeat the `en` calls for the same 20 cells. Record whether each `isoCountryCode` and `administrativeArea` is unchanged.

## Measure

| Quantity | Expected | Observed |
|---|---|---|
| `isoCountryCode` present (en) | yes | |
| `administrativeArea` present (en) | yes | |
| `locality` present (en) | usually | |
| Throttle error at 20 per minute | none | |
| First error at burst, `CLError` code | unknown | |
| Requests before first error | unknown | |
| Key unchanged after 24 hours | yes | |

Duration: 1–2 hours hands-on, about 1 day wall time.

## Results

### Owner to fill in

| Cell | Place (en: iso, area, locality) | Place (vi: area, locality) | Missing fields | Notes |
|---|---|---|---|---|
|  |  |  |  |  |

| Question | Answer |
|---|---|
| Throttle at 20 per minute |  |
| First error at burst (code, count) |  |
| Key unchanged after 24 hours (count of 20) |  |
| Vietnamese names read correctly |  |

Conclusions (free text):

## Changes this result drives

| Setting or constant | File and symbol | Default now |
|---|---|---|
| Structured-field requirement | `Sources/PhotoVaultCore/Policies/PlaceNamingPolicy.swift`, `identity(_:)` | ISO code and administrative area required; a cell without them is unusable |
| Display language | `Sources/PhotoVaultCore/Models/Settings.swift`, `GlobalSettings.placeNameLanguage` | `vi` |
| Home country | `GlobalSettings.homeCountryCode` | `VN` |
| Geocoder | `Sources/PhotoVaultPhotos/CLGeocoderReverseGeocoder.swift`, `reverseGeocode(cell:locale:)` | `CLGeocoder`, cell centre |
| Rate limit | `Sources/PhotoVaultEngine/GeocodeScheduler.swift`, `requestsPerMinute` | 20 per sliding minute |
| Country-only fallback | `GeocodeScheduler.swift`, `adapt` and the `place_country_only` flag | 3 consecutive results without province |

Decisions to update: [0019](../decisions/0019-place-naming-edge-choices.md), [0008](../decisions/0008-geocoding-privacy.md). If the fallback triggers often, check the names it produces. The spec asks the app to tell the owner when it falls back (FR-84, "báo owner"); the code's notice is not verified.
