import Foundation
import Testing
@testable import PhotoVaultCore

@Suite struct ImportDatePolicyTests {
    let vietnam = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    let modified = Date(timeIntervalSince1970: 1_700_500_000)

    func entry(created: Date? = nil, modified: Date? = nil) -> FolderFileEntry {
        FolderFileEntry(relativePath: "a.jpg", uti: "public.jpeg", sizeBytes: 1, creationDate: created, modificationDate: modified)
    }

    @Test func exifWithOffset() {
        let meta = FileMetadata(capture: CaptureMetadata(dateTimeOriginal: "2025:03:01 07:55:30", offsetTime: "+02:00"))
        let result = ImportDatePolicy.captureDate(metadata: meta, entry: entry(created: created), archiveTimeZone: vietnam)
        #expect(result.source == .exif)
        #expect(result.date == ISO8601DateFormatter().date(from: "2025-03-01T05:55:30Z"))
    }

    @Test func exifWithoutOffsetUsesArchiveTimezone() {
        let meta = FileMetadata(capture: CaptureMetadata(dateTimeOriginal: "2025:03:01 07:55:30"))
        let result = ImportDatePolicy.captureDate(metadata: meta, entry: entry(), archiveTimeZone: vietnam)
        #expect(result.source == .exif)
        #expect(result.date == ISO8601DateFormatter().date(from: "2025-03-01T00:55:30Z"))
    }

    @Test func invalidExifFallsThrough() {
        let meta = FileMetadata(capture: CaptureMetadata(dateTimeOriginal: "0000:00:00 00:00:00"))
        let result = ImportDatePolicy.captureDate(metadata: meta, entry: entry(created: created), archiveTimeZone: vietnam)
        #expect(result.source == .fileDate && result.date == created)
        let garbage = FileMetadata(capture: CaptureMetadata(dateTimeOriginal: "yesterday"))
        #expect(ImportDatePolicy.captureDate(metadata: garbage, entry: entry(), archiveTimeZone: vietnam).date == nil)
    }

    @Test func videoDate() {
        let video = Date(timeIntervalSince1970: 1_650_000_000)
        let result = ImportDatePolicy.captureDate(metadata: FileMetadata(captureDate: video), entry: entry(created: created), archiveTimeZone: vietnam)
        #expect(result.source == .video && result.date == video)
    }

    @Test func fileDateIsTheEarlierOfCreationAndModification() {
        let both = ImportDatePolicy.captureDate(metadata: .empty, entry: entry(created: modified, modified: created), archiveTimeZone: vietnam)
        #expect(both.source == .fileDate && both.date == created)
        let onlyModified = ImportDatePolicy.captureDate(metadata: .empty, entry: entry(modified: modified), archiveTimeZone: vietnam)
        #expect(onlyModified.date == modified)
        let none = ImportDatePolicy.captureDate(metadata: .empty, entry: entry(), archiveTimeZone: vietnam)
        #expect(none.date == nil && none.source == .fileDate)
    }
}
