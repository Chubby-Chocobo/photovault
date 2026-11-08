import Foundation
import PhotoVaultCore

/// How the Mac disk compares with the watermarks (FR-31, spec 8.5).
public enum MacDiskState: Sendable, Equatable {
    case ok
    /// Below `lowWatermark`: backfill waits.
    case low
    /// Below `criticalWatermark`: every export stops.
    case critical

    public static func classify(freeBytes: Int64, settings: GlobalSettings) -> MacDiskState {
        if freeBytes < settings.criticalWatermarkBytes { return .critical }
        if freeBytes < settings.lowWatermarkBytes { return .low }
        return .ok
    }

    /// Free space at which a blocked backfill continues (`lowWatermark + 5 GB`, spec 8.5).
    public static func resumeBytes(settings: GlobalSettings) -> Int64 {
        settings.lowWatermarkBytes + DiskGuardPolicy.margin
    }

    /// Onboarding summary: "Cần giải phóng X GB" with X = lowWatermark + 5 GB - free; nil when free
    /// space is not below `lowWatermark`.
    public static func bytesToFree(freeBytes: Int64, settings: GlobalSettings) -> Int64? {
        guard freeBytes < settings.lowWatermarkBytes else { return nil }
        return resumeBytes(settings: settings) - freeBytes
    }
}
