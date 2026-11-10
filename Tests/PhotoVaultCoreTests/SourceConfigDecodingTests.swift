import Foundation
import Testing
@testable import PhotoVaultCore

@Suite struct SourceConfigDecodingTests {
    @Test func rowsWrittenBeforeTheSyncedProviderStillDecode() throws {
        let old = Data(#"{"bookmark":"AQID","account":"a@b.c"}"#.utf8)
        let config = try JSONDecoder().decode(SourceConfig.self, from: old)
        #expect(config.account == "a@b.c")
        #expect(config.syncedProvider == nil)
        #expect(config.syncedCloudProvider == nil)
    }

    @Test func syncedProviderRoundTrips() throws {
        var config = SourceConfig(bookmark: Data([1]))
        config.syncedCloudProvider = .dropbox
        let back = try JSONDecoder().decode(SourceConfig.self, from: JSONEncoder().encode(config))
        #expect(back.syncedProvider == "dropbox")
        #expect(back.syncedCloudProvider == .dropbox)
    }

    @Test func aProviderThisVersionDoesNotKnowIsIgnoredNotFatal() throws {
        let future = Data(#"{"syncedProvider":"onedrive"}"#.utf8)
        let config = try JSONDecoder().decode(SourceConfig.self, from: future)
        #expect(config.syncedCloudProvider == nil)
    }

    @Test func theInitializerStoresTheProvider() {
        let config = SourceConfig(bookmark: Data([1]), syncedProvider: .googleDrive)
        #expect(config.syncedProvider == "googleDrive")
        #expect(config.syncedCloudProvider == .googleDrive)
        #expect(SourceConfig(bookmark: Data([1])).syncedProvider == nil)
    }
}
