import CoreLocation
import Foundation
import PhotoVaultCore

/// `ReverseGeocoding` over `CLGeocoder`. Only the cell centre is sent (FR-85).
/// `CLGeocoder` is deprecated on the newest SDKs in favour of MapKit; it is kept because it needs no
/// extra entitlement.
public struct CLGeocoderReverseGeocoder: ReverseGeocoding {
    public init() {}

    public func reverseGeocode(cell: GeoCell, locale: String) async throws -> GeoPlace {
        let center = cell.center
        let location = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let placemarks: [CLPlacemark]
        do {
            placemarks = try await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: Locale(identifier: locale))
        } catch {
            // Open sea and other unnamed places are an answer, not a failure: an empty place is cached
            // like any other, so the scheduler moves on instead of retrying this cell first forever.
            if Self.isNoResult(error) { return GeoPlace() }
            throw error
        }
        guard let placemark = placemarks.first else { return GeoPlace() }
        return GeoPlace(
            isoCountryCode: placemark.isoCountryCode,
            country: placemark.country,
            administrativeArea: placemark.administrativeArea,
            locality: placemark.locality
        )
    }

    static func isNoResult(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == kCLErrorDomain && ns.code == CLError.Code.geocodeFoundNoResult.rawValue
    }
}
