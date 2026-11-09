# M0-6: Geocoder quality, throttling and key stability

- **Status:** run 2026-11-09 (fields, throttle, names); the 24-hour key check is still to do
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

Run on 2026-11-09, macOS 26.6.2, through `CLGeocoderReverseGeocoder` on the cell centre. The 20 points are well-known public places, not coordinates from the library (the probe chose them so no owner location left the Mac); they cover the same cases the procedure asks for. Raw log kept outside the repo (`~/photovault-spikes/logs/`).

| Cell | Place (en: iso, area, locality) | Place (vi: area, locality) | Missing fields | Notes |
|---|---|---|---|---|
| Đà Lạt centre | VN, Lam Dong, Lam Vien - Da Lat | Lâm Đồng, P. Lâm Viên - Đà Lạt | none | locality is the ward |
| Đà Lạt, Tuyền Lâm lake | VN, Lam Dong, Xuan Huong - Da Lat | Lâm Đồng, P. Xuân Hương - Đà Lạt | none | |
| Hà Nội, Hoàn Kiếm | VN, Ha Noi, Cua Nam | Thành Phố Hà Nội, P. Cửa Nam | none | `vi` area has the "Thành Phố" prefix |
| Hà Nội, Tây Hồ | VN, Ha Noi, Hong Ha | Thành Phố Hà Nội, P. Hồng Hà | none | |
| Hội An old town | VN, Da Nang, Hoi An Dong | Thành Phố Đà Nẵng, P. Hội An Đông | none | 2025 merger: Quảng Nam is now Đà Nẵng |
| Huế citadel | VN, Hue, Phu Xuan | Thành Phố Huế, P. Phú Xuân | none | |
| TP HCM, Quận 1 | VN, Ho Chi Minh City, Sai Gon | Thành Phố Hồ Chí Minh, P. Sài Gòn | none | |
| Đà Nẵng, Mỹ Khê | VN, Da Nang, Ngu Hanh Son | Thành Phố Đà Nẵng, P. Ngũ Hành Sơn | none | |
| Sa Pa | VN, Lao Cai, Sa Pa | Lào Cai, P. Sa Pa | none | |
| Phú Quốc | VN, An Giang, Phu Quoc | An Giang, Đặc Khu Phú Quốc | none | 2025 merger: Kiên Giang is now An Giang |
| Hạ Long bay (water) | VN, —, — | —, — | area, locality | country only on water |
| Mũi Cà Mau | VN, Ca Mau, Dat Mui | Cà Mau, X. Đất Mũi | none | |
| Móng Cái (border) | VN, Quang Ninh, Mong Cai 1 | Quảng Ninh, P. Móng Cái 1 | none | |
| Lào Cai (border) | VN, Lao Cai, Lao Cai | Lào Cai, P. Lào Cai | none | |
| Tokyo, Shibuya | JP, Tokyo, Shibuya | Tokyo, Shibuya | none | `vi` country "Nhật Bản" |
| Kyoto | JP, Kyoto, Kyoto | Kyoto, Kyoto | none | |
| Bangkok | TH, Bangkok, Phra Nakhon District | Bangkok, Khet Phra Nakhon | none | |
| Paris | FR, Île-de-France, Paris | Île-de-France, Thủ đô Paris | none | |
| South China Sea (open sea) | —, —, — | —, — | all | no error: an empty answer (`geocodeFoundNoResult` is not raised through this path) |
| Gobi desert | MN, Ömnögovi, — | Nam Gobi Aymag, — | locality | |

| Question | Answer |
|---|---|
| Throttle at 20 per minute | none: 60 of 60 in 196 s |
| First error at burst (code, count) | `CLError` code 2 (`network`) on request 51, after 50 successes in 6 s |
| Key unchanged after 24 hours (count of 20) | to do: repeat `probe geo-fields` after 2026-11-10 10:30 and compare the `en` columns |
| Vietnamese names read correctly | yes, with diacritics; localities carry the ward prefixes "P." (phường), "X." (xã), "Đặc Khu" |

Conclusions:

- **Fields are present on land everywhere tested** (17 of 17 land cells have ISO code and area in `en`). A missing province means water, not lost fields.
- **Bug found and fixed.** Hạ Long bay answers with a country and no province. The country-only fallback started after 3 such answers in a row, so a boat trip switched the whole library to country names. It then stored "Vietnam" as the area of the water cells. That clashed with the Quảng Ninh cells on shore, so the day lost its name. The fallback now starts only when no answer has carried a province since the last refresh, after 10 in a row. A province arriving later undoes it. Test: `PlaceNameTests.aBoatTripStillNamesTheDayAfterItsProvince`.
- **Throttling shows up as a network error**, which the scheduler already backs off on. The 20-per-minute limit is well below what Apple allows.
- **Apple's data follows the 2025 merger of provinces and the removal of districts.** Keys such as `VN|Quang Nam` (old cache) and `VN|Da Nang` (new answer) name the same place. Cached answers stay as they are until "Làm mới địa danh", which then renames those days.
- **How a one-ward day is named: kept as it is (owner, 2026-11-09).** The locality is now a ward. A day spent in one ward is named after it, prefix included, for example "P. Cửa Nam" or "P. Lâm Viên - Đà Lạt", rather than the city. FR-81 (same locality → locality) is unchanged. The owner turned down using the province when the locality starts with "P.", "X." or "Đặc Khu".

## Changes this result drives

| Setting or constant | File and symbol | Default now |
|---|---|---|
| Structured-field requirement | `Sources/PhotoVaultCore/Policies/PlaceNamingPolicy.swift`, `identity(_:)` | ISO code and administrative area required; a cell without them is unusable |
| Name languages | `Sources/PhotoVaultCore/Policies/PlaceNameRule.swift` (decision 0023) | `en` + `vi` in Vietnam, `en` + native language abroad |
| Home country | `GlobalSettings.homeCountryCode` | `VN` |
| Geocoder | `Sources/PhotoVaultPhotos/CLGeocoderReverseGeocoder.swift`, `reverseGeocode(cell:locale:)` | `CLGeocoder`, cell centre |
| Rate limit | `Sources/PhotoVaultEngine/GeocodeScheduler.swift`, `requestsPerMinute` | 20 per sliding minute |
| Country-only fallback | `GeocodeScheduler.swift`, `adapt` and the `place_country_only` flag | 3 consecutive results without province |

Decisions to update: [0019](../decisions/0019-place-naming-edge-choices.md), [0008](../decisions/0008-geocoding-privacy.md). If the fallback triggers often, check the names it produces. The spec asks the app to tell the owner when it falls back (FR-84, "báo owner"); the code's notice is not verified.
