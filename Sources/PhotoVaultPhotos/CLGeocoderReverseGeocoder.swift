import CoreLocation
import Foundation
import PhotoVaultCore

/// `ReverseGeocoding` over `CLGeocoder`. Only the cell centre is sent (FR-85).
/// `CLGeocoder` is deprecated on the newest SDKs in favour of MapKit; it is kept because it needs no
/// extra entitlement.
public struct CLGeocoderReverseGeocoder: ReverseGeocoding {
    public enum GeocodingError: Error, Equatable {
        case noResult
    }

    public init() {}

    public func reverseGeocode(cell: GeoCell, locale: String) async throws -> GeoPlace {
        let center = cell.center
        let location = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let placemarks = try await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: Locale(identifier: locale))
        guard let placemark = placemarks.first else { throw GeocodingError.noResult }
        return GeoPlace(
            isoCountryCode: placemark.isoCountryCode,
            country: placemark.country,
            administrativeArea: placemark.administrativeArea,
            locality: placemark.locality
        )
    }
}
