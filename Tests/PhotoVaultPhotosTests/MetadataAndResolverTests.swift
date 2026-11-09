import CoreLocation
import ImageIO
import Foundation
import PhotoVaultCore
import Testing
import UniformTypeIdentifiers
@testable import PhotoVaultPhotos

struct ImageIOMetadataReaderTests {
    private let reader = ImageIOMetadataReader()

    private func write(_ data: Data, ext: String) throws -> URL {
        let url = TestImages.tempURL("\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    @Test func readsAllFieldsFromJPEG() throws {
        let spec = TestImages.Spec(make: "Sony", model: "ILCE-7M4", lens: "FE 35mm", dateTimeOriginal: "2023:12:24 18:30:00", offset: "+01:00")
        let url = try write(try #require(TestImages.make(type: .jpeg, spec: spec)), ext: "jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let metadata = reader.metadata(of: url, uti: "public.jpeg", mediaType: .image)
        #expect(metadata.make == "Sony")
        #expect(metadata.model == "ILCE-7M4")
        #expect(metadata.lensModel == "FE 35mm")
        #expect(metadata.dateTimeOriginal == "2023:12:24 18:30:00")
        #expect(metadata.offsetTime == "+01:00")
        #expect(metadata.hasCameraIdentity)
    }

    /// Staged files carry no extension: the reader tells ImageIO the resource's type.
    @Test func stagedFilesAreReadAsTheirResourceType() throws {
        let url = TestImages.tempURL(UUID().uuidString)
        try #require(TestImages.make(type: .tiff)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try #require(ImageIOMetadataReader.imageSource(of: url, uti: "com.sony.arw-raw-image"))
        #expect(CGImageSourceGetType(source) as String? == "com.sony.arw-raw-image")
    }

    @Test func jpegWithoutCameraIdentityHasNone() throws {
        let url = try write(try #require(TestImages.make(type: .jpeg)), ext: "jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let metadata = reader.metadata(of: url, uti: "public.jpeg", mediaType: .image)
        #expect(!metadata.hasCameraIdentity)
    }

    @Test func heicRoundTrip() throws {
        guard let heic = TestImages.make(type: .heic, spec: TestImages.Spec(make: "Apple", model: "iPhone 15")) else { return }
        let url = try write(heic, ext: "heic")
        defer { try? FileManager.default.removeItem(at: url) }
        let metadata = reader.metadata(of: url, uti: "public.heic", mediaType: .image)
        #expect(metadata.make == "Apple")
        #expect(metadata.model == "iPhone 15")
    }

    @Test func unreadableFilesYieldEmpty() throws {
        let missing = TestImages.tempURL("missing.jpg")
        #expect(reader.metadata(of: missing, uti: "public.jpeg", mediaType: .image) == .empty)
        #expect(reader.metadata(of: missing, uti: "public.mpeg-4", mediaType: .video) == .empty)
        let junk = try write(Data(repeating: 7, count: 100), ext: "mov")
        defer { try? FileManager.default.removeItem(at: junk) }
        #expect(reader.metadata(of: junk, uti: "com.apple.quicktime-movie", mediaType: .video) == .empty)
    }
}

struct UTTypeResolverTests {
    private let resolver = UTTypeResolver()

    @Test func rawDetection() {
        #expect(resolver.isRaw("com.sony.arw-raw-image"))
        #expect(resolver.isRaw("com.adobe.raw-image"))
        #expect(!resolver.isRaw("public.heic"))
        #expect(!resolver.isRaw("public.jpeg"))
        #expect(!resolver.isRaw("not.a.real.uti.zzz"))
    }

    @Test func preferredExtensions() {
        #expect(resolver.preferredExtension(for: "public.heic") == "heic")
        #expect(resolver.preferredExtension(for: "public.jpeg") == "jpeg")
        #expect(resolver.preferredExtension(for: "com.adobe.raw-image") == "dng")
        #expect(resolver.preferredExtension(for: "com.sony.arw-raw-image") == "arw")
    }
}

struct PhotosErrorMapperTests {
    @Test func photosCodes() {
        #expect(PhotosErrorMapper.map(domain: "PHPhotosErrorDomain", code: 3105) == .tokenExpired)
        #expect(PhotosErrorMapper.map(domain: "PHPhotosErrorDomain", code: 3210) == .changeDetailsUnavailable)
        #expect(PhotosErrorMapper.map(domain: "PHPhotosErrorDomain", code: 3169) == .networkError)
        for offline in [3114, 3142, 3143] {
            #expect(PhotosErrorMapper.map(domain: "PHPhotosErrorDomain", code: offline) == .libraryUnavailable, "library away: \(offline)")
        }
        #expect(PhotosErrorMapper.map(domain: "PHPhotosErrorDomain", code: 1) == .other(code: 1, domain: "PHPhotosErrorDomain"))
        #expect(PhotosErrorMapper.map(domain: NSURLErrorDomain, code: -1009) == .networkError)
    }

    @Test func batching() {
        #expect(PhotoKitSource.batches(Array(0..<1_001), size: 500).map(\.count) == [500, 500, 1])
        #expect(PhotoKitSource.batches([Int](), size: 500).isEmpty)
    }
}

struct GeocoderNoResultTests {
    @Test func noResultIsAnAnswerNotAFailure() {
        #expect(CLGeocoderReverseGeocoder.isNoResult(NSError(domain: kCLErrorDomain, code: CLError.Code.geocodeFoundNoResult.rawValue)))
        #expect(!CLGeocoderReverseGeocoder.isNoResult(NSError(domain: kCLErrorDomain, code: CLError.Code.network.rawValue)))
    }
}
