import Foundation
import Photos
import PhotoVaultCore

/// Maps PhotoKit and Foundation errors to `PhotosSourceError`.
enum PhotosErrorMapper {
    static func map(_ error: Error) -> PhotosSourceError {
        if let known = error as? PhotosSourceError { return known }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        return map(domain: ns.domain, code: ns.code)
    }

    static func map(domain: String, code: Int) -> PhotosSourceError {
        if domain == PHPhotosErrorDomain {
            switch code {
            case 3105: return .tokenExpired                  // persistentChangeTokenExpired
            case 3210: return .changeDetailsUnavailable      // persistentChangeDetailsUnavailable
            case 3164, 3169: return .networkError            // networkAccessRequired, networkError
            case 3072: return .cancelled                     // userCancelled
            case 3310, 3311: return .notAuthorized           // accessRestricted, accessUserDenied
            // libraryVolumeOffline, relinquishingLibraryBundleToWriter, switchingSystemPhotoLibrary:
            // the whole library is away, so no single resource should spend its retries.
            case 3114, 3142, 3143: return .libraryUnavailable
            default: return .other(code: code, domain: domain)
            }
        }
        if domain == NSURLErrorDomain { return .networkError }
        return .other(code: code, domain: domain)
    }

    static func map(_ failure: StreamingFileWriter.Failure) -> PhotosSourceError {
        switch failure {
        case .stopped: .cancelled
        case .io(let code, let domain): .other(code: code, domain: domain)
        }
    }
}
