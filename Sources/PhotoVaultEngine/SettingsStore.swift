import Foundation
import PhotoVaultCore
import PhotoVaultStore

/// Immutable view of the settings a pipeline step works with.
public struct SettingsSnapshot: Sendable, Equatable {
    public var settings: GlobalSettings
    public var timeZone: TimeZone
}

/// Global settings and the archive timezone, persisted in `kv` (the archive timezone is fixed on
/// first launch and never follows the system timezone, spec 8.6).
public actor SettingsStore {
    static let settingsKey = "global_settings"

    private let store: Store
    private let log: any LogSink
    private var settings: GlobalSettings
    private var timeZone: TimeZone
    /// Last queued update; the next one starts when it ends, so updates apply in call order.
    private var updateTail: Task<GlobalSettings, any Error>?

    public init(store: Store, defaultTimeZone: TimeZone = .current, log: any LogSink = NullLogSink()) throws {
        self.store = store
        self.log = log
        let loaded: (GlobalSettings?, TimeZone?) = try store.read { db in
            (try KeyValueRepository.data(db, Self.settingsKey).map { Self.decode($0, log: log) }, try KeyValueRepository.archiveTimeZone(db))
        }
        settings = loaded.0 ?? GlobalSettings()
        timeZone = loaded.1 ?? defaultTimeZone
        if loaded.1 == nil {
            let zone = defaultTimeZone
            try store.write { db in try KeyValueRepository.setArchiveTimeZone(db, zone) }
        }
    }

    public func snapshot() -> SettingsSnapshot { SettingsSnapshot(settings: settings, timeZone: timeZone) }

    /// Decodes stored settings key by key over the defaults: a key a newer or older release does
    /// not know, or one that no longer decodes, costs only that setting instead of all of them.
    static func decode(_ data: Data, log: any LogSink) -> GlobalSettings {
        let decoder = JSONDecoder()
        if let whole = try? decoder.decode(GlobalSettings.self, from: data) { return whole }
        guard let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaults = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(GlobalSettings()))) as? [String: Any]
        else {
            log.log(.error, category: "settings", "stored settings are not a JSON object; using defaults")
            return GlobalSettings()
        }
        var merged = defaults
        for (key, value) in stored where defaults[key] != nil {
            var candidate = merged
            candidate[key] = value
            if let json = try? JSONSerialization.data(withJSONObject: candidate), (try? decoder.decode(GlobalSettings.self, from: json)) != nil {
                merged = candidate
            } else {
                log.log(.error, category: "settings", "stored setting could not be read; using its default")
            }
        }
        guard let json = try? JSONSerialization.data(withJSONObject: merged), let result = try? decoder.decode(GlobalSettings.self, from: json) else {
            return GlobalSettings()
        }
        return result
    }

    /// Applies `mutate` and persists the result. Callers re-run eligibility afterwards. The read,
    /// the change and the write happen in one transaction, and updates run one after another, so
    /// none is lost.
    @discardableResult
    public func update(_ mutate: @escaping @Sendable (inout GlobalSettings) -> Void) async throws -> GlobalSettings {
        let previous = updateTail
        let task = Task { [self] () throws -> GlobalSettings in
            _ = await previous?.result
            return try await applyUpdate(mutate)
        }
        updateTail = task
        return try await task.value
    }

    private func applyUpdate(_ mutate: @escaping @Sendable (inout GlobalSettings) -> Void) async throws -> GlobalSettings {
        let fallback = settings
        let log = log
        let next = try await store.write { db in
            var value = try KeyValueRepository.data(db, Self.settingsKey).map { Self.decode($0, log: log) } ?? fallback
            mutate(&value)
            try KeyValueRepository.set(db, Self.settingsKey, try JSONEncoder().encode(value))
            return value
        }
        settings = next
        return next
    }

    /// Changing the archive timezone recomputes `creation_day` only; placements stay (8.1).
    public func setArchiveTimeZone(_ zone: TimeZone) async throws {
        try await store.write { db in
            try KeyValueRepository.setArchiveTimeZone(db, zone)
            try AssetRepository.recomputeCreationDays(db, timeZone: zone)
        }
        timeZone = zone
    }
}
