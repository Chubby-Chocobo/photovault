import Foundation
import Testing
@testable import PhotoVaultCore

@Suite struct ContentAssetKeyTests {
    let hash = String(repeating: "ab", count: 32)

    @Test func contentKeyRoundTrips() throws {
        let key = try #require(AssetKey.content(sha256: hash))
        #expect(key.rawValue == "x:" + hash && key.isContent && !key.isCloud)
        #expect(key.identifier == hash)
        #expect(key.appPropertyValue() == key.rawValue)
        #expect(key.appPropertyValue().utf8.count + AppPropertyKey.assetId.utf8.count <= AppPropertyCodec.maxPairBytes)
        let decoded = try JSONDecoder().decode(AssetKey.self, from: JSONEncoder().encode(key))
        #expect(decoded == key)
    }

    @Test func badHashIsRejected() {
        #expect(AssetKey.content(sha256: "abc") == nil)
        #expect(AssetKey.content(sha256: String(repeating: "AB", count: 32)) == nil)
        #expect(AssetKey.content(sha256: String(repeating: "g", count: 64)) == nil)
        #expect(AssetKey(rawValue: "x:") == nil)
        #expect(AssetKey(rawValue: "x:1") == nil)
        #expect(AssetKey.local("A").isContent == false)
    }

    @Test func sourceIdsAndLocators() throws {
        let uuid = UUID()
        let id = SourceID.folder(uuid)
        #expect(id.rawValue == "folder-" + uuid.uuidString.lowercased() && id.kind == .localFolder)
        #expect(SourceID(rawValue: id.rawValue) == id)
        #expect(SourceID(rawValue: "folder-" + uuid.uuidString.uppercased()) == nil)
        #expect(SourceID(rawValue: "folder-nope") == nil && SourceID(rawValue: "x") == nil)
        #expect(SourceID.photos.kind == .photos)
        let decoded = try JSONDecoder().decode(SourceID.self, from: JSONEncoder().encode(id))
        #expect(decoded == id)

        let locator = ImportLocator(sourceId: id, relativePath: "2024/Tet/IMG_1.HEIC")
        #expect(ImportLocator(localId: locator.localId) == locator)
        #expect(locator.directory == "2024/Tet" && locator.sibling(named: "IMG_1.MOV") == "2024/Tet/IMG_1.MOV")
        let top = ImportLocator(sourceId: id, relativePath: "a.jpg")
        #expect(top.directory == "" && top.sibling(named: "a.dng") == "a.dng")
        #expect(ImportLocator(localId: "ABC/L0/001") == nil)
        #expect(ImportLocator(localId: id.rawValue + "/") == nil)
        // NFD input is stored as NFC.
        let nfd = ImportLocator(sourceId: id, relativePath: "Ha\u{0300}/a.jpg")
        #expect(nfd.relativePath == "H\u{00E0}/a.jpg")
    }

    @Test func assetRecordDefaultsToPhotos() {
        let record = AssetRecord(assetKey: .local("A"), localId: "A", mediaType: .image, firstSeenAt: .now, lastSeenAt: .now)
        #expect(record.sourceId == .photos)
    }
}
