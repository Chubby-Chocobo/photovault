import Foundation
import Testing
@testable import PhotoVaultCore
import PhotoVaultTestSupport

@Suite struct ModelsAndCodecsTests {
    @Test func assetKeyPrefixesAndHash() throws {
        #expect(AssetKey(rawValue: "x:1") == nil)
        let key = AssetKey.cloud("ABC")
        #expect(key.rawValue == "c:ABC" && key.isCloud && key.identifier == "ABC")
        #expect(key.appPropertyValue() == "c:ABC")
        let long = AssetKey.cloud(String(repeating: "A", count: 200))
        #expect(long.appPropertyValue().hasPrefix("h:"))
        #expect(long.appPropertyValue().count == 34)
        let decoded = try JSONDecoder().decode(AssetKey.self, from: JSONEncoder().encode(key))
        #expect(decoded == key)
    }

    @Test func resourceTypeRawValuesMatchPhotoKitAndRoundTrip() {
        #expect(ResourceType.photo.rawValue == 1)
        #expect(ResourceType.pairedVideo.rawValue == 9)
        #expect(ResourceType.photoProxy.rawValue == 19)
        #expect(ResourceType(rawValue: 1001) == .sidecarJson)
        #expect(ResourceType(rawValue: 42) == .unknown(42))
        for raw in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 19, 1001, 1002, 77] {
            let t = ResourceType(rawValue: raw)
            #expect(ResourceType(rawValue: t.rawValue) == t)
            #expect(AppPropertyCodec.decodeResourceType(AppPropertyCodec.encode(t)) == t)
        }
        #expect(ResourceType.fullSizePhoto.kind == .edited)
        #expect(ResourceType.sidecarXmp.kind == .sidecarXmp)
    }

    @Test func archiveDayParsingAndTimezone() {
        #expect(ArchiveDay(string: "2026-02-30") == nil)
        #expect(ArchiveDay(string: "2026-11-08")?.description == "2026-11-08")
        let date = ISO8601DateFormatter().date(from: "2026-11-08T20:00:00Z")!
        #expect(ArchiveDay(date: date, timeZone: TimeZone(identifier: "Asia/Ho_Chi_Minh")!).description == "2026-11-09")
        #expect(ArchiveDay(date: date, timeZone: TimeZone(identifier: "UTC")!).description == "2026-11-08")
        #expect(PlacementDay(string: "unknown") == .unknown)
    }

    @Test func destinationIdsAndStatus() {
        #expect(DestinationID(rawValue: "local-nope") == nil)
        let local = DestinationID.local()
        #expect(DestinationID(rawValue: local.rawValue) == local && local.kind == .localFolder)
        let status = DestinationStatus.paused(.rootTrashed)
        #expect(DestinationStatus(storageName: status.storageName, reason: status.reason) == status)
        #expect(status.description == "paused(rootTrashed)")
    }

    @Test func appPropertiesForFilesFoldersAndRoot() {
        let props = AppPropertyCodec.fileProperties(assetKey: .local("L1"), resType: .fullSizePhoto, category: .saved)
        #expect(props == ["pvAssetId": "l:L1", "pvResType": "fullSizePhoto", "pvKind": "edited", "pvCategory": "saved", "pvSchema": "1"])
        let longPath = String(repeating: "x/", count: 80)
        #expect(AppPropertyCodec.folderProperties(logicalPath: longPath, view: .byPlace)["pvLogical"]?.hasPrefix("h:") == true)
        let root = AppPropertyCodec.rootProperties(archiveTimezone: TimeZone(identifier: "Asia/Ho_Chi_Minh")!)
        #expect(root["pvRoot"] == "1" && root["pvArchiveTZ"] == "Asia/Ho_Chi_Minh")
    }

    @Test func errorClassification() {
        #expect(ErrorClassifier.classify(.offline) == .destinationLevel(.unavailable(.offline)))
        #expect(ErrorClassifier.classify(.server(status: 503)) == .transient)
        #expect(ErrorClassifier.classify(.server(status: 503), consecutiveFailures: 3) == .destinationLevel(nil))
        #expect(ErrorClassifier.classify(.checksumMismatch(expected: "a", actual: "b")) == .itemLevel)
        #expect(ErrorClassifier.classify(.foreignModified) == .permanent(.foreignModified))
        #expect(ErrorClassifier.classify(.alreadyExists(remoteId: "x")) == .verify)
        #expect(ErrorClassifier.destinationError(httpStatus: 403, reason: "storageQuotaExceeded") == .quotaExceeded)
        #expect(ErrorClassifier.destinationError(httpStatus: 308, reason: nil) == nil)
        #expect(ErrorClassifier.destinationError(errno: ENOSPC) == .noSpace)
    }

    @Test func exportControlCheckpointsAndCancel() {
        let control = ExportControl(checkpointBytes: 100) { total in total < 250 }
        #expect(control.record(bytes: 90))
        #expect(control.record(bytes: 90), "checkpoint at 180 allows")
        #expect(control.record(bytes: 90), "no checkpoint until 280")
        #expect(!control.record(bytes: 90), "checkpoint at 360 refuses")
        #expect(control.isCancelled && control.bytesReceived == 360)
        let manual = ExportControl()
        manual.cancel()
        #expect(!manual.record(bytes: 1))
    }

    @Test func redactedNeverPrintsValue() {
        let secret = Redacted("ya29.token")
        #expect("\(secret)" == "<redacted>")
        #expect(!"\(SessionCheckpoint(sessionRef: "https://upload?id=SECRET", md5: "m", totalBytes: 1))".contains("SECRET"))
    }

    @Test func fakeDestinationsPassConformance() async throws {
        for reserving in [true, false] {
            let fake = FakeDestination(id: reserving ? .googleDrive : .local(), reservesIds: reserving)
            let suite = DestinationConformanceSuite(destination: fake, root: fake.root, scratch: try TestFiles.temporaryDirectory())
            let failures = await suite.run()
            #expect(failures.isEmpty, "\(reserving ? "drive-like" : "local-like"): \(failures)")
            #expect(await fake.contractViolations.isEmpty)
        }
    }
}
