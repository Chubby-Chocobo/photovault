import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// Why a running export was stopped from outside.
enum ExportCancelReason: Sendable, Equatable {
    case disk, sizeRule
}

private final class WeakPermit: @unchecked Sendable {
    weak var permit: ExportPermit?
}

/// One admitted export or classification read. The control is shared with the PhotoKit data
/// handler; `reason` records who cancelled it.
final class ExportPermit: @unchecked Sendable {
    let id = UUID()
    let control: ExportControl
    let isRateLimited: Bool
    let freeBytesAtStart: Int64
    let estimatedBytes: Int64
    /// Memory or disk the work may hold before bytes are counted as received (a header read buffers up to its cap).
    let reservedBytes: Int64
    private let lock = NSLock()
    private var cancelReason: ExportCancelReason?

    init(isRateLimited: Bool, freeBytesAtStart: Int64, estimatedBytes: Int64, reservedBytes: Int64 = 0, checkpointBytes: Int64,
         checkpoint: @escaping @Sendable (ExportPermit, Int64) -> Bool) {
        self.isRateLimited = isRateLimited
        self.freeBytesAtStart = freeBytesAtStart
        self.estimatedBytes = estimatedBytes
        self.reservedBytes = reservedBytes
        let box = WeakPermit()
        control = ExportControl(checkpointBytes: checkpointBytes) { received in
            guard let permit = box.permit else { return true }
            return checkpoint(permit, received)
        }
        box.permit = self
    }

    var reason: ExportCancelReason? { lock.withLock { cancelReason } }

    func cancel(_ reason: ExportCancelReason) {
        lock.withLock { if cancelReason == nil { cancelReason = reason } }
        control.cancel()
    }
}

public enum AdmissionDenial: Sendable, Equatable {
    /// Nothing may start now: critical disk or staging full. The caller stops dispatching.
    case stopAll(DiskGuardBlock)
    /// Only rate-limited work is held back (low disk, power, thermal, token bucket); the caller
    /// moves on to the next candidate.
    case rateLimited(DiskGuardBlock?)
}

enum Admission {
    case granted(ExportPermit)
    case denied(AdmissionDenial)
}

/// The single decision point for starting exports and classification reads (FR-31, spec 8.5).
/// All inputs that need a suspension are gathered first; the decision and the registration of the
/// permit then happen without suspending, so two admissions can never both pass the staging cap.
actor ResourceGuard {
    private let env: EngineEnvironment
    private let staging: StagingManager
    private var active: [UUID: ExportPermit] = [:]
    private var rateLimitedPaused = false
    private var bucket: TokenBucket?
    private var bucketRate: Int64 = 0

    init(env: EngineEnvironment, staging: StagingManager) {
        self.env = env
        self.staging = staging
    }

    var activeCount: Int { active.count }

    /// Decides whether an export (or classification read) may start.
    /// - Parameters:
    ///   - rateLimited: backfill, re-export (`export_count >= 1`) or non-incremental classification.
    ///   - estimatedBytes: size used for the token bucket until the real size is known.
    ///   - sizeLimit: FR-33 cap; the stream is cancelled when every needing destination's cap is exceeded.
    ///   - reservedBytes: counted as in flight (against the staging cap) until the work has received more.
    func admit(rateLimited: Bool, estimatedBytes: Int64, sizeLimit: Int64?, reservedBytes: Int64 = 0) async -> Admission {
        let settings = await env.settingsSnapshot().settings
        var system = await env.system.snapshot()
        let stagedBytes = (try? await staging.stagedBytes()) ?? 0
        let now = env.clock.now
        // From here on there is no suspension until the permit is registered.
        guard let capacity = try? env.disk.capacity(of: env.stagingDirectory) else {
            return .denied(.stopAll(.criticalDisk))
        }
        if !settings.backfillOnlyOnACPower { system.onACPower = true }
        let inFlight = active.values.reduce(Int64(0)) { $0 + max($1.control.bytesReceived, $1.reservedBytes, 0) }
        let input = DiskGuardInput(
            capacity: capacity, stagingBytes: stagedBytes, inFlightBytes: inFlight, activeExportCount: active.count,
            settings: settings, isRateLimited: rateLimited, system: system, rateLimitedPaused: rateLimitedPaused)
        let decision = DiskGuardPolicy.evaluate(input)
        rateLimitedPaused = decision.rateLimitedPaused
        if decision.mustCancelAll { cancelAllActive() }
        if let block = decision.blockedBy {
            switch block {
            case .criticalDisk, .stagingFull: return .denied(.stopAll(block))
            case .lowDisk, .notOnACPower, .lowPowerMode, .thermal: return .denied(.rateLimited(block))
            }
        }
        if rateLimited {
            var current = currentBucket(settings)
            guard current.tryConsume(bytes: max(estimatedBytes, 1), at: now) else {
                bucket = current
                return .denied(.rateLimited(nil))
            }
            bucket = current
        }
        let critical = settings.criticalWatermarkBytes
        let disk = env.disk
        let url = env.stagingDirectory
        let permit = ExportPermit(
            isRateLimited: rateLimited, freeBytesAtStart: capacity.available, estimatedBytes: estimatedBytes, reservedBytes: reservedBytes,
            checkpointBytes: env.tuning.exportCheckpointBytes
        ) { permit, received in
            if let sizeLimit, received > sizeLimit {
                permit.cancel(.sizeRule)
                return false
            }
            if let free = try? disk.capacity(of: url).available, free < critical {
                permit.cancel(.disk)
                return false
            }
            return true
        }
        active[permit.id] = permit
        return .granted(permit)
    }

    /// Ends a permit. `actualBytes` trues up the token bucket when the real size exceeded the estimate.
    func finish(_ permit: ExportPermit, actualBytes: Int64?) async {
        active[permit.id] = nil
        guard permit.isRateLimited, let actualBytes, actualBytes > permit.estimatedBytes else { return }
        let settings = await env.settingsSnapshot().settings
        var current = currentBucket(settings)
        let now = env.clock.now
        let extra = min(actualBytes - permit.estimatedBytes, current.available(at: now))
        if extra > 0 { _ = current.tryConsume(bytes: extra, at: now) }
        bucket = current
    }

    /// Takes `bytes` from the backfill bucket's upload lane (edit-gate fallback re-exports).
    func tryConsumeBackfill(bytes: Int64) async -> Bool {
        let settings = await env.settingsSnapshot().settings
        var current = currentBucket(settings)
        let allowed = current.tryConsume(bytes: max(bytes, 1), lane: .upload, at: env.clock.now)
        bucket = current
        return allowed
    }

    /// Nominal cost of one Drive metadata or view write against the shared bucket (FR-49).
    static let metadataWriteCost: Int64 = 16 << 10

    /// Admits one Drive metadata or view write; uploads keep the reserved part of the bucket.
    func admitMetadataWrite() async -> Bool {
        let settings = await env.settingsSnapshot().settings
        var current = currentBucket(settings)
        let allowed = current.tryConsume(bytes: Self.metadataWriteCost, lane: .metadata, at: env.clock.now)
        bucket = current
        return allowed
    }

    /// Re-evaluates the disk (called at every cycle step): below the critical watermark every
    /// running export is cancelled so its partial file can be removed.
    @discardableResult
    func enforce() async -> Bool {
        let settings = await env.settingsSnapshot().settings
        guard let capacity = try? env.disk.capacity(of: env.stagingDirectory) else { return false }
        let critical = capacity.available < settings.criticalWatermarkBytes
        await recordDiskFull(critical)
        guard critical else { return false }
        cancelAllActive()
        return true
    }

    /// Keeps `kv.mac_disk_full_since` (FR-61): set at the first pass that finds the disk below the
    /// critical watermark, cleared once it is above again. The owner is told when it lasts 24 hours.
    private func recordDiskFull(_ full: Bool) async {
        let now = env.clock.now
        let key = KeyValueRepository.Key.macDiskFullSince
        do {
            try await env.store.write { db in
                let since = try KeyValueRepository.date(db, key)
                if full, since == nil { try KeyValueRepository.set(db, key, now) }
                if !full, since != nil { try KeyValueRepository.set(db, key, nil) }
            }
        } catch {
            env.log.log(.error, category: "disk", "could not record the disk-full time: \(type(of: error))")
        }
    }

    private func cancelAllActive() {
        for permit in active.values { permit.cancel(.disk) }
    }

    private func currentBucket(_ settings: GlobalSettings) -> TokenBucket {
        let rate = max(settings.backfillBytesPerHour, 1)
        if let bucket, bucketRate == rate { return bucket }
        bucketRate = rate
        return TokenBucket(capacity: rate, refillPerHour: rate)
    }
}
