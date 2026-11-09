import Foundation

/// Builds the per-destination sidecars (FR-90..92, 8.12). Pure and deterministic: the same
/// `SidecarInput` gives byte-identical files; nothing depends on the generation time.
/// `buildJSON` lives in `SidecarJSON.swift`, `buildXMP` in `SidecarXMP.swift`.
public enum SidecarBuilder {}
