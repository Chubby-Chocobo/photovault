import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultLocal
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// A folder on disk the tests import from, with the metadata each file "contains".
final class ImportFolder: @unchecked Sendable {
    let url: URL
    let reader: StubFileMetadataReader
    let id = SourceID.folder()

    init() throws {
        reader = StubFileMetadataReader()
        url = try TestFiles.temporaryDirectory("import").resolvingSymlinksInPath().appendingPathComponent("Trip", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Writes a file whose bytes are `content` (distinct content, distinct hash).
    @discardableResult
    func add(_ relative: String, _ content: String? = nil, metadata: FileMetadata? = nil) throws -> URL {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((content ?? "bytes-of-\(relative)").utf8).write(to: file)
        if let metadata { reader.set(relative, metadata) }
        return file
    }

    /// The same folder and metadata under a new job (importing it again).
    init(again other: ImportFolder) {
        url = other.url
        reader = other.reader
    }

    func source() -> LocalFolderSource { LocalFolderSource(id: id, root: PlainURLRoot(url), metadata: reader) }

    /// Metadata of a camera photo taken at `date` (whole seconds, UTC).
    static func photo(at date: Date, make: String? = "Apple", model: String? = "iPhone 15", width: Int = 4000, height: Int = 3000,
                      location: GeoPoint? = nil, screenshot: Bool = false) -> FileMetadata {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return FileMetadata(
            capture: CaptureMetadata(make: make, model: model, dateTimeOriginal: formatter.string(from: date), offsetTime: "+00:00"),
            pixelWidth: width, pixelHeight: height, location: location, isScreenshot: screenshot)
    }
}

extension Harness {
    /// Starts an import of `folder` and lets the cycle run until it has nothing left to do.
    @discardableResult
    func startImport(_ folder: ImportFolder, settle rounds: Int = 6) async throws -> SourceID {
        let id = try await coordinator.startFolderImport(source: folder.source(), displayName: "Trip", bookmark: nil)
        await settle(rounds: rounds)
        return id
    }

    func source(_ id: SourceID) throws -> SourceRecord? { try read { db in try SourceRepository.fetch(db, id: id) } }
    func importCounts(_ id: SourceID) throws -> [ImportItemState: Int] { try read { db in try ImportItemRepository.counts(db, sourceId: id) } }

    func importActivity() throws -> [ActivityEvent] {
        try read { db in try ActivityRepository.recent(db).filter { $0.kind == .milestone && $0.message.contains("thư mục") } }
    }

    func assets(of id: SourceID) throws -> [AssetRecord] {
        try read { db in
            try AssetKey.fetchKeys(db, sourceId: id).compactMap { try AssetRepository.fetch(db, key: $0) }
        }
    }
}

extension AssetKey {
    static func fetchKeys(_ db: Database, sourceId: SourceID) throws -> [AssetKey] {
        try String.fetchAll(db, sql: "SELECT asset_key FROM asset WHERE source_id = ? ORDER BY asset_key", arguments: [sourceId.rawValue])
            .compactMap(AssetKey.init(rawValue:))
    }
}
