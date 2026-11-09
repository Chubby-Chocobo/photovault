import Foundation
import PhotoVaultCore

struct VolumeDiskSpaceProvider: DiskSpaceProvider {
    func capacity(of url: URL) throws -> DiskCapacity {
        var target = url
        // The staging folder may not exist yet; its volume is the volume of the nearest existing parent.
        while !FileManager.default.fileExists(atPath: target.path), target.pathComponents.count > 1 {
            target.deleteLastPathComponent()
        }
        let values = try target.resourceValues(forKeys: [
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ])
        let available = Int64(values.volumeAvailableCapacity ?? 0)
        return DiskCapacity(
            available: available, availableForImportantUsage: values.volumeAvailableCapacityForImportantUsage ?? available,
            total: Int64(values.volumeTotalCapacity ?? 0))
    }
}
