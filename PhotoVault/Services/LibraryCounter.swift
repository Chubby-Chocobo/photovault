import Foundation
import Photos
import PhotoVaultCore

/// Asset counts for the sync-mode options (FR-06). Counts only; no sizes (PhotoKit has no public size API).
enum LibraryCounter {
    /// Assets created on or after `day` (start of day in the archive timezone), hidden assets and all burst frames included.
    static func count(since day: ArchiveDay?, timeZone: TimeZone) async -> Int {
        await Task.detached(priority: .utility) {
            let options = PHFetchOptions()
            options.includeHiddenAssets = true
            options.includeAllBurstAssets = true
            if let day {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = timeZone
                if let start = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) {
                    options.predicate = NSPredicate(format: "creationDate >= %@", start as NSDate)
                }
            }
            return PHAsset.fetchAssets(with: options).count
        }.value
    }
}
