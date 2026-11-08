# 0006 macOS 27 extended-metadata APIs unavailable; deployment target macOS 14

- **Status:** Accepted (the M0-2 result may still move the deployment target)
- **Spec refs:** FR-10 (`prefetchAssetExtendedMetadata`), FR-91 (`caption`, `keywords`), FR-92, FR-94, §6 ("macOS 14+ (chốt sau M0-2)")
- **Review trigger:** when the owner builds with the macOS 27 SDK, or M0-2 changes the target

## Context

`PHAssetExtendedMetadata` and `prefetchAssetExtendedMetadata` are not in the macOS 26.5 SDK on the build machine, as recorded in the plan's Decisions section. The code cannot compile or verify them.

## Decision

- `MACOSX_DEPLOYMENT_TARGET = 14.0` in `Config/Base.xcconfig`; `platforms: [.macOS(.v14)]` in `Package.swift`.
- `SidecarInput.extendedMetadata` is `nil` by default. When it is `nil`, the JSON sidecar writes `"extendedMetadata": "unavailable"` and no `caption` or `keywords` keys appear.
- The XMP packet omits `dc:description` and `dc:subject` when there is no extended metadata (`SidecarXMP.swift`).
- The code that reads the extended metadata is to sit behind a capability check. It is not in the code yet, because the API is not in the SDK here.

## Consequences

- Captions and keywords are never written on macOS 26 builds. README "known limits" says so.
- The sidecar schema has an `extendedMetadata` marker, documented in [sidecar-schema.md](../sidecar-schema.md).
- Raising the deployment target above 14 requires a new decision.
