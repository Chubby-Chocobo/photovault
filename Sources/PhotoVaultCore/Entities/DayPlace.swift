import Foundation

/// Row of `day_place`: an extra folder of a split camera day (`camera/<day>@<slot>`).
/// The main folder of the day is described by `DayStat`.
public struct DayPlace: Hashable, Codable, Sendable {
    public var day: ArchiveDay
    public var slot: String
    /// `<iso>|<administrativeArea en>`; nil for an unnamed group.
    public var placeKey: String?
    public var placeName: String?

    public init(day: ArchiveDay, slot: String, placeKey: String? = nil, placeName: String? = nil) {
        self.day = day
        self.slot = slot
        self.placeKey = placeKey
        self.placeName = placeName
    }
}
