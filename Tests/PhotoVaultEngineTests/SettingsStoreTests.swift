import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

@Suite struct SettingsStoreTests {
    private func stored(_ json: String, log: RecordingLogSink = RecordingLogSink()) throws -> SettingsStore {
        let store = try Store.inMemory()
        try store.write { db in try KeyValueRepository.set(db, SettingsStore.settingsKey, Data(json.utf8)) }
        return try SettingsStore(store: store, defaultTimeZone: TimeZone(identifier: "UTC")!, log: log)
    }

    @Test func aKeyMissingFromTheStoredJsonKeepsTheOtherChoices() async throws {
        let settings = try stored(#"{"includeVideos": false, "integrityCheckIntervalDays": 25}"#)
        let value = await settings.snapshot().settings
        #expect(!value.includeVideos)
        #expect(value.integrityCheckIntervalDays == 25)
        #expect(value.includeEdited == GlobalSettings().includeEdited)
    }

    @Test func settingsSavedBeforeTheLensViewDecodeWithItOff() async throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(GlobalSettings())) as? [String: Any])
        object.removeValue(forKey: "viewByLensEnabled")
        object["viewFavoritesEnabled"] = false
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let value = await (try stored(json)).snapshot().settings
        #expect(!value.viewByLensEnabled)
        #expect(!value.viewFavoritesEnabled, "the other choices survive")
    }

    @Test func aSettingThatNoLongerDecodesFallsBackOnlyForThatKey() async throws {
        let log = RecordingLogSink()
        let settings = try stored(#"{"includeVideos": false, "integrityCheckIntervalDays": "many"}"#, log: log)
        let value = await settings.snapshot().settings
        #expect(!value.includeVideos)
        #expect(value.integrityCheckIntervalDays == GlobalSettings().integrityCheckIntervalDays)
        #expect(log.lines.contains { $0.contains("settings:") })
    }

    @Test func storedJsonFromANewerReleaseWithExtraKeysIsRead() async throws {
        let settings = try stored(#"{"includeVideos": false, "someFutureSwitch": true}"#)
        #expect(await !settings.snapshot().settings.includeVideos)
    }

    @Test func concurrentUpdatesAreAllKept() async throws {
        let store = try Store.inMemory()
        let settings = try SettingsStore(store: store, defaultTimeZone: TimeZone(identifier: "UTC")!)
        async let first: GlobalSettings = settings.update { $0.includeVideos = false }
        async let second: GlobalSettings = settings.update { $0.includeHidden = true }
        async let third: GlobalSettings = settings.update { $0.integrityCheckIntervalDays = 42 }
        _ = try await (first, second, third)
        let value = await settings.snapshot().settings
        #expect(!value.includeVideos)
        #expect(value.includeHidden)
        #expect(value.integrityCheckIntervalDays == 42)
        let reopened = try SettingsStore(store: store, defaultTimeZone: TimeZone(identifier: "UTC")!)
        #expect(await reopened.snapshot().settings == value)
    }
}
