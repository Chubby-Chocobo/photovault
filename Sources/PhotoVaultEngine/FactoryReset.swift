import Foundation

/// Factory Reset: the app starts over from onboarding. Confirming writes a marker and relaunches;
/// the next process, holding the instance lock and before opening the database, empties the data
/// folder. Nothing at any destination is touched. A crash halfway leaves the marker, so the next
/// launch finishes the job.
public enum FactoryReset {
    public static let markerName = "factory-reset-requested"
    /// Google counts the daily upload limit per account, not per database, so its counter stays.
    public static let dailyCapFileName = "drive-daily-cap.json"

    static func marker(_ layout: ContainerLayout) -> URL { layout.root.appendingPathComponent(markerName) }

    public static func request(_ layout: ContainerLayout) throws {
        try Data().write(to: marker(layout), options: .atomic)
    }

    public static func isRequested(_ layout: ContainerLayout) -> Bool {
        FileManager.default.fileExists(atPath: marker(layout).path)
    }

    /// Empties the data folder when a reset was requested; returns whether it did. The marker goes
    /// last, so an error leaves it for the next launch.
    @discardableResult
    public static func applyIfRequested(_ layout: ContainerLayout) throws -> Bool {
        guard isRequested(layout) else { return false }
        let fileManager = FileManager.default
        let kept: Set<String> = [InstanceLock.fileName, dailyCapFileName, markerName]
        for item in try fileManager.contentsOfDirectory(at: layout.root, includingPropertiesForKeys: nil)
        where !kept.contains(item.lastPathComponent) {
            try fileManager.removeItem(at: item)
        }
        try fileManager.removeItem(at: marker(layout))
        return true
    }
}
