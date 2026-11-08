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
    private var settings: GlobalSettings
    private var timeZone: TimeZone

    public init(store: Store, defaultTimeZone: TimeZone = .current) throws {
        self.store = store
        let loaded: (GlobalSettings?, TimeZone?) = try store.read { db in
            let json = try KeyValueRepository.data(db, Self.settingsKey).flatMap { try? JSONDecoder().decode(GlobalSettings.self, from: $0) }
            return (json, try KeyValueRepository.archiveTimeZone(db))
        }
        settings = loaded.0 ?? GlobalSettings()
        timeZone = loaded.1 ?? defaultTimeZone
        if loaded.1 == nil {
            let zone = defaultTimeZone
            try store.write { db in try KeyValueRepository.setArchiveTimeZone(db, zone) }
        }
    }

    public func snapshot() -> SettingsSnapshot { SettingsSnapshot(settings: settings, timeZone: timeZone) }

    /// Applies `mutate` and persists the result. Callers re-run eligibility afterwards.
    @discardableResult
    public func update(_ mutate: @Sendable (inout GlobalSettings) -> Void) async throws -> GlobalSettings {
        var next = settings
        mutate(&next)
        let data = try JSONEncoder().encode(next)
        try await store.write { db in try KeyValueRepository.set(db, Self.settingsKey, data) }
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
