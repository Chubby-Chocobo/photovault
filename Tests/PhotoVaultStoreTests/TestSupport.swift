import Foundation
import GRDB
import PhotoVaultCore
@testable import PhotoVaultStore

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
let utc = TimeZone(identifier: "UTC")!
let vietnam = TimeZone(identifier: "Asia/Ho_Chi_Minh")!

func makeAsset(
    _ id: String, created: Date? = t0, category: AssetCategory? = .camera, insertedAt: Date? = nil
) -> AssetRecord {
    AssetRecord(
        assetKey: .local(id), localId: id, creationDate: created, mediaType: .image, category: category,
        insertedAt: insertedAt, firstSeenAt: t0, lastSeenAt: t0)
}

func makeResource(_ key: AssetKey, _ type: ResourceType = .photo, state: StagingState = .none, stagingGen: Int = 0) -> ResourceRecord {
    ResourceRecord(
        assetKey: key, type: type, originalFilename: "IMG_0001.HEIC", uti: "public.heic",
        stagingGen: stagingGen, stagingState: state)
}

func makeDestination(_ id: DestinationID = .googleDrive) -> DestinationRecord {
    DestinationRecord(id: id, displayName: "Drive", statusSince: t0, createdAt: t0)
}

func desired(_ dest: DestinationID, _ key: AssetKey, _ type: ResourceType = .photo, origin: JobOrigin = .incremental, gen: Int = 1) -> JobTransitions.Desired {
    .init(identity: JobIdentity(destinationId: dest, assetKey: key, resType: type), origin: origin, targetGen: gen)
}

func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pv-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
