import Foundation

/// Everything the disk guard needs for one decision (FR-31, 8.5). The same input shape serves
/// exports and classification reads; classification reads pass `isRateLimited: false`.
public struct DiskGuardInput: Sendable {
    public var capacity: DiskCapacity
    public var stagingBytes: Int64
    public var inFlightBytes: Int64
    public var activeExportCount: Int
    public var lowWatermarkBytes: Int64
    public var criticalWatermarkBytes: Int64
    public var stagingSoftLimitBytes: Int64
    /// The export to start counts against the backfill / re-export rate limit (8.5).
    public var isRateLimited: Bool
    public var system: SystemSnapshot
    /// Hysteresis state returned by the previous decision.
    public var rateLimitedPaused: Bool

    public init(
        capacity: DiskCapacity, stagingBytes: Int64, inFlightBytes: Int64, activeExportCount: Int,
        settings: GlobalSettings, isRateLimited: Bool, system: SystemSnapshot, rateLimitedPaused: Bool = false
    ) {
        self.capacity = capacity
        self.stagingBytes = stagingBytes
        self.inFlightBytes = inFlightBytes
        self.activeExportCount = activeExportCount
        self.lowWatermarkBytes = settings.lowWatermarkBytes
        self.criticalWatermarkBytes = settings.criticalWatermarkBytes
        self.stagingSoftLimitBytes = settings.stagingSoftLimitBytes
        self.isRateLimited = isRateLimited
        self.system = system
        self.rateLimitedPaused = rateLimitedPaused
    }
}

public enum DiskGuardBlock: String, Sendable, CaseIterable {
    case criticalDisk, lowDisk, notOnACPower, lowPowerMode, thermal, stagingFull
}

public struct DiskGuardDecision: Hashable, Sendable {
    public var mayStartExport: Bool
    /// Free space is below critical: cancel every running export and remove partial files.
    public var mustCancelAll: Bool
    /// Rate-limited exports must stop (low disk or power / thermal conditions).
    public var stopRateLimitedExports: Bool
    /// New hysteresis state; feed it back into the next input.
    public var rateLimitedPaused: Bool
    public var blockedBy: DiskGuardBlock?
}

public enum DiskGuardPolicy {
    /// Margin above the low watermark (resume) and above critical (too-large test and retry).
    public static let margin: Int64 = 5 * GlobalSettings.GiB
    public static let cancelsBeforeTooLarge = 2

    /// Real free space (`volumeAvailableCapacity`) drives both watermarks: it is what the
    /// volume can actually write, whereas purgeable space is not under our control.
    public static func evaluate(_ input: DiskGuardInput) -> DiskGuardDecision {
        let free = input.capacity.available
        let critical = free < input.criticalWatermarkBytes

        var paused = input.rateLimitedPaused
        if free < input.lowWatermarkBytes {
            paused = true
        } else if paused && free >= input.lowWatermarkBytes + margin {
            paused = false
        }

        let powerBlock = powerBlock(input.system)
        let stopRateLimited = paused || powerBlock != nil

        var blocked: DiskGuardBlock?
        if critical {
            blocked = .criticalDisk
        } else if input.isRateLimited && paused {
            blocked = .lowDisk
        } else if input.isRateLimited, let powerBlock {
            blocked = powerBlock
        } else if !stagingAllows(input) {
            blocked = .stagingFull
        }
        return DiskGuardDecision(
            mayStartExport: blocked == nil, mustCancelAll: critical,
            stopRateLimitedExports: stopRateLimited, rateLimitedPaused: paused, blockedBy: blocked
        )
    }

    /// Soft staging limit with the single-export exception: with nothing staged and no export
    /// running, one export is always admitted so a file larger than the limit can still run.
    private static func stagingAllows(_ input: DiskGuardInput) -> Bool {
        if input.stagingBytes == 0 && input.inFlightBytes == 0 && input.activeExportCount == 0 { return true }
        return input.stagingBytes + input.inFlightBytes < input.stagingSoftLimitBytes
    }

    private static func powerBlock(_ system: SystemSnapshot) -> DiskGuardBlock? {
        if !system.onACPower { return .notOnACPower }
        if system.lowPowerMode { return .lowPowerMode }
        if system.thermal >= .serious { return .thermal }
        return nil
    }

    /// After two disk cancels, a file whose received bytes plus the free space at start could
    /// not even reach critical + margin is too large for this disk (FR-31).
    public static func isTooLargeForDisk(
        diskCancelCount: Int, bytesReceivedAtCancel: Int64?, freeAtStart: Int64, criticalWatermarkBytes: Int64
    ) -> Bool {
        guard diskCancelCount >= cancelsBeforeTooLarge, let received = bytesReceivedAtCancel else { return false }
        return received + freeAtStart < criticalWatermarkBytes + margin
    }

    /// A `tooLargeForDisk` file is retried automatically only when its size is known and fits.
    public static func mayRetryTooLarge(freeBytes: Int64, knownSizeBytes: Int64?) -> Bool {
        guard let knownSizeBytes else { return false }
        return freeBytes >= knownSizeBytes + margin
    }
}
