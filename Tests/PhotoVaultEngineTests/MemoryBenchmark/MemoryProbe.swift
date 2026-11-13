import Darwin
import Foundation

/// Reads this process's physical footprint, the number Activity Monitor and `footprint` show.
enum MemoryProbe {
    struct Reading { var current: UInt64; var lifetimePeak: UInt64 }

    static func read() -> Reading {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return Reading(current: 0, lifetimePeak: 0) }
        return Reading(current: usage.ri_phys_footprint, lifetimePeak: usage.ri_lifetime_max_phys_footprint)
    }

    /// Bytes malloc hands out now (live heap) and bytes it holds from the system, over all zones.
    static func heap() -> (inUse: UInt64, held: UInt64) {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return (UInt64(stats.size_in_use), UInt64(stats.size_allocated))
    }

    /// How far the footprint rose; zero when it fell (malloc can give back memory taken before the start).
    static func growth(from start: UInt64, to peak: UInt64) -> UInt64 { peak > start ? peak - start : 0 }

    static func megabytes(_ bytes: UInt64) -> String { String(format: "%.1f", Double(bytes) / 1_048_576) }
}

/// Samples the footprint on its own thread while a scenario runs and keeps the highest value seen.
final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var highest: UInt64 = 0
    private var running = true
    private let done = DispatchSemaphore(value: 0)

    init(intervalMicroseconds: UInt32 = 2_000) {
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let now = MemoryProbe.read().current
                lock.withLock { highest = max(highest, now) }
                usleep(intervalMicroseconds)
            }
            done.signal()
        }
    }

    /// Stops sampling and returns the highest footprint seen.
    func stop() -> UInt64 {
        lock.withLock { running = false }
        done.wait()
        return lock.withLock { max(highest, MemoryProbe.read().current) }
    }
}
