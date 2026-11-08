import Foundation
@testable import PhotoVaultCore

enum PolicyFixtures {
    static let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    static let vietnam = TimeZone(identifier: "Asia/Ho_Chi_Minh")!

    static func asset(
        _ key: String = "l:A", category: AssetCategory? = .camera, day: ArchiveDay? = ArchiveDay(year: 2025, month: 3, day: 1),
        make: String? = nil, model: String? = nil, favorite: Bool = false, hidden: Bool = false,
        location: GeoPoint? = nil, deleted: Bool = false
    ) -> AssetRecord {
        var record = AssetRecord(
            assetKey: .local(String(key.dropFirst(2))), localId: String(key.dropFirst(2)),
            creationDate: Date(timeIntervalSince1970: 1_740_790_530.25), mediaType: .image,
            category: category, isHidden: hidden, isFavorite: favorite, location: location,
            cameraMake: make, cameraModel: model, firstSeenAt: t0, lastSeenAt: t0,
            deletedAt: deleted ? t0 : nil
        )
        if let category {
            record.placement = Placement(category: category, day: day.map { .day($0) } ?? .unknown, nameStem: "stem")
        }
        record.geoCell = location.map(GeoCell.init)
        return record
    }

    /// Deterministic generator for jitter tests (SplitMix64).
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
