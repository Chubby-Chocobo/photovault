# 0008 Geocoding sends only grid-cell centres; hidden and deleted assets excluded from place naming

- **Status:** Accepted (review later)
- **Spec refs:** FR-84, FR-85, FR-106, NFR-06, §9
- **Review trigger:** when the owner decides on hidden assets in place names, or when the engine wiring lands (Phase 09)

## Context

FR-85 promises that coordinates sent to Apple are rounded to about 1 km. Hidden photos must not leak into visible folder names. The spec is silent on whether hidden assets count for place naming.

## Decision

- `CLGeocoderReverseGeocoder.reverseGeocode(cell:locale:)` sends `cell.center` only. `GeoCell` is a 0.01° grid (`GeoCell.size = 0.01`), so the request carries the centre of that cell, not the photo's coordinates.
- `PlaceNamingPolicy.evaluate` skips deleted assets and, unless `includeHidden` is on, hidden assets. Only the remaining cells are geocoded.
- The geocode cache is keyed by cell and locale (`geo_cache`), so each cell is sent once per locale.

## Consequences

- A place name is computed from the cell centre. The centre is at most about 0.8 km from the photo (half the cell diagonal, about 0.56 km × √2 at this latitude).
- The asset's own coordinates are not rounded in the local database. The JSON sidecar writes them to 6 decimals (`location.latitude`, `location.longitude`), as spec FR-91 requires. This is separate from geocoding. README "Privacy" covers it.
- `GeocodeScheduler` (engine) makes the requests. It sends nothing when place names are off, and it keeps to the rate limit in [0019](0019-place-naming-edge-choices.md). The engine is still changing; re-check this file when Phase 09 lands.
