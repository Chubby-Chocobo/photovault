# 0023 Day folders in every branch, and one fixed rule for place-name languages

- **Status:** Accepted
- **Spec refs:** FR-40, FR-82, FR-84, FR-104 to FR-106, §8.7 (all amended); replaces the place-name language part of FR-82 and the N threshold of FR-40
- **Review trigger:** the owner wants month folders back, or a country whose native name comes out in the wrong language

## Context

The first layout put camera photos in `YYYY/MM/` and gave a day its own folder only past N photos, with place names in a language picked in Settings. On 2026-11-09 (issue #12) the owner asked for a folder per day under a `Camera Uploads` branch, with names that do not depend on a setting: the country in English, places in Vietnam in Vietnamese ("Hà Nội", not "Thành phố Hà Nội"), places abroad in English with the native name ("Kyoto (京都市)").

## Decision

- **Layout** (`DynamicLayout`): `Camera Uploads/YYYY-MM-DD[ <place>]/`, `Screenshots/YYYY-MM-DD/`, `Saved/YYYY-MM-DD/`, `<branch>/Unknown date/`; views end in the day: `By device/<group>/<day>/`, `By place/<country>/<area>/<day>/`, `Favorites/<day>/`. The default root name is `PhotoVault`.
- **No threshold:** the layout does not depend on `day_stat.promoted`, so a file never moves because its day filled up. Promotion stays only as "this day gets a place name", set at the day's first camera asset.
- **Place names** (`PlaceNameRule`): each cell is geocoded in `en` (identity and English names) and once in a second locale — `vi` in Vietnam, the country's primary language from CLDR likely subtags elsewhere (`zh-Hans`/`zh-Hant` keep the script), none for English-speaking countries. The second answer is cached under the locale key `local`. Vietnamese province/city prefixes are dropped; ward and commune prefixes stay (owner, earlier decision). The rule follows where the place is, not the home-country setting, which only decides the country suffix of a day folder.
- **Settings removed:** the N threshold, "Sắp xếp lại", the place-name language.

## Alternatives

- Keep the threshold with the new branch folder: the owner wants every day as a folder.
- Remove promotion from the schema: much larger change for no visible difference.
- A per-country locale key in the cache: the scheduler would need the country before it knows which key to look for.

## Consequences

- No migration from the `YYYY/MM` layout. Updating means using Settings › Nâng cao › Đặt lại từ đầu… (the factory reset), letting onboarding run again, and moving the old root to the Trash by hand (the app never deletes files on destinations). Do not delete the database by hand: the app stops syncing a database in the old layout and tells the owner to start over, and it does not offer an old root for reuse ([0025](0025-old-layout-block-and-reset.md)).
- Same geocoding budget as before: at most two requests per cell.
- A country with several official languages gets one of them (Switzerland → German, India → Hindi).
