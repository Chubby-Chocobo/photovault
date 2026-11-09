# 0019 Place naming: edge-case choices for day-folder names

- **Status:** Accepted after M0-6 (2026-11-09), with the country-only fallback changed; the 24-hour key check is open. A day in one ward keeps the ward's name (for example "P. Cửa Nam"), as the owner chose on 2026-11-09
- **Spec refs:** FR-80 to FR-83, FR-106, §8.11, T28, T36, T38
- **Review trigger:** after M0-6 ([spike](../spikes/m0-6-geocoder-quality.md)), or when the owner changes how a day with mixed places is named

## Context

`PlaceNamingPolicy.evaluate` (`Policies/PlaceNamingPolicy.swift`) is pure: no clock, no geocoding. The spec (FR-80 to FR-83, §8.11) is silent on the edge cases below.

## Decision

The code chooses:

| Case | Choice in the code |
|---|---|
| Day ended less than 6 hours ago | `pending`; no geocoding |
| No camera asset with GPS | `unnamed` |
| Deleted asset | excluded from the cell set |
| Hidden asset, with Hidden upload off | excluded (see [0008](0008-geocoding-privacy.md)) |
| Bounding box diagonal above 300 km | `unnamed` |
| More than 30 cells | 30 representatives, always including the northmost, southmost, eastmost and westmost cells (`representativeCells`) |
| A cell with no ISO code or no administrative area | not usable; skipped. If no cell is usable, `unnamed` |
| Usable cells with more than one `isoCountryCode\|administrativeArea` identity | `unnamed` (spec FR-81: all cells must share the same key) |
| Usable cells with the same locality (English key) | the locality is shown |
| Usable cells with different locality, or a missing locality | the administrative area is shown |
| Place outside the home country (`homeCountryCode`, default `VN`) | `<name>, <country>`, where the country comes from the display geocode, else the English one |
| Display locale differs from `en` and a display geocode is missing | `waitingGeocode`, with the missing cells listed |

Name lookup uses the English key to decide identity; the shown text follows `PlaceNameRule` (decision [0023](0023-day-folders-and-place-name-rule.md): English country, Vietnamese names in Vietnam, English plus native name abroad). A missing second-locale answer falls back to the English one.

## Geocoder requests and the country-only fallback

These live in `GeocodeScheduler` (engine), not in the pure policy:

| Behaviour | Choice in the code |
|---|---|
| Rate limit | at most 20 requests in a sliding 60-second window (`requestsPerMinute`); exponential backoff after errors (`Backoff`) |
| Country-only fallback (spec FR-84, "giảm cấp xuống chỉ quốc gia") | after 10 consecutive English results that have a country but no province, and only if no answer has carried a province since the last refresh, the scheduler stores the country as the administrative area for those cells and sets the `place_country_only` flag. A province arriving later clears the flag and asks the rewritten cells again. M0-6 showed that water cells (Hạ Long bay) answer with a country and no province, so the earlier rule of 3 in a row fired on a boat trip |
| Clearing the fallback | "Làm mới địa danh" (`refreshAll`) deletes the geocode cache and the flag |

## Consequences

- A day that mixes a locality with a missing one is named by area. This is conservative: a wrong locality is worse than a broader name.
- Whether these choices hold depends on what the geocoder returns (M0-6). The fallback is a guess that the country name can stand in for the area, so the owner should check the names it produces. The flag clears itself when a province arrives, and on "Làm mới địa danh".
- The fallback is in the engine and is covered by its tests, not by the pure policy's tests.
