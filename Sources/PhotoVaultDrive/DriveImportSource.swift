import Foundation
import PhotoVaultCore

/// Files the owner picked on Google Drive (plus what Google lets the app read inside picked folders),
/// read once to import. Read-only: it only issues GET requests. Errors are `SourceError`.
public final class DriveImportSource: FolderImportSource, Sendable {
    public let id: SourceID
    let http: DriveHTTP
    let lister: DriveImportLister
    let metadata: any FileMetadataReading
    let scratchDirectory: URL
    let index = PathIndex()

    /// Remembers which Drive file a relative path names. Empty after a relaunch until the next listing.
    actor PathIndex {
        private var ids: [String: String] = [:]
        private var listed = false
        func replace(_ ids: [String: String]) { self.ids = ids; listed = true }
        func lookup(_ path: String) -> String? { ids[path] }
        var hasListed: Bool { listed }
    }

    /// - Parameters:
    ///   - pickedIds: Drive ids the owner picked.
    ///   - scratchDirectory: where `inspect` puts its temporary copy; created when missing.
    public init(id: SourceID, pickedIds: [String], auth: any DriveAuthorizing, transport: any HTTPTransport,
                scratchDirectory: URL, metadata: any FileMetadataReading) {
        self.id = id
        http = DriveHTTP(transport: transport, auth: auth)
        lister = DriveImportLister(http: http, pickedIds: pickedIds)
        self.metadata = metadata
        self.scratchDirectory = scratchDirectory
    }

    public func probe() async throws {
        guard let first = lister.pickedIds.first else { throw SourceError.unavailable }
        do { _ = try await lister.item(first) } catch DestinationError.notFound {
            // A picked item that was deleted still means Drive answered.
            return
        } catch { throw Self.map(error, forFile: false) }
    }

    /// Name of the picked folder when exactly one folder was picked, for the import's display name.
    /// nil for several picks, a single file, or when Drive does not answer.
    public func singlePickedFolderName() async -> String? {
        guard lister.pickedIds.count == 1, let id = lister.pickedIds.first,
              let item = try? await lister.item(id), item.isFolder, item.trashed != true,
              let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }

    public func listFiles() async throws -> [FolderFileEntry] {
        do {
            let listing = try await lister.list()
            await index.replace(listing.ids)
            return listing.entries
        } catch { throw Self.map(error, forFile: false) }
    }

    public func inspect(relativePath: String, uti: String, mediaType: MediaType, control: ExportControl) async throws -> InspectedFile {
        let fileId = try await resolve(relativePath)
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let ext = (relativePath as NSString).pathExtension
        let scratch = scratchDirectory.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try await download(fileId, to: scratch, control: control)
        return InspectedFile(size: file.size, sha256: file.sha256,
                             metadata: metadata.fileMetadata(of: scratch, uti: uti, mediaType: mediaType))
    }

    public func exportResource(_ locator: ResourceLocator, to destination: URL, control: ExportControl) async throws -> ExportedFile {
        guard let primary = ImportLocator(localId: locator.localId), primary.sourceId == id else { throw SourceError.fileMissing }
        let fileId = try await resolve(primary.sibling(named: locator.originalFilename))
        return try await download(fileId, to: destination, control: control)
    }

    // MARK: Internals

    /// Drive id of a path; a path unknown after a relaunch triggers one listing.
    func resolve(_ relativePath: String) async throws -> String {
        let path = relativePath.precomposedStringWithCanonicalMapping
        if let found = await index.lookup(path) { return found }
        if !(await index.hasListed) { _ = try await listFiles() }
        guard let found = await index.lookup(path) else { throw SourceError.fileMissing }
        return found
    }

    private func download(_ fileId: String, to url: URL, control: ExportControl) async throws -> ExportedFile {
        let writer: StreamingFileWriter
        do { writer = try StreamingFileWriter(url: url, control: control) } catch let failure as StreamingFileWriter.Failure {
            throw Self.map(failure)
        }
        let media = DriveURL.make(DriveURL.api, "/files/" + FormEncoding.escape(fileId), [("alt", "media")])
        do {
            try await http.download(media) { chunk in
                if !writer.append(chunk) { throw writer.failure.map(Self.map) ?? SourceError.cancelled }
            }
            return try writer.finish()
        } catch {
            writer.abort()
            throw Self.map(error, forFile: true)
        }
    }

    // MARK: Errors

    static func map(_ failure: StreamingFileWriter.Failure) -> SourceError {
        switch failure {
        case .stopped: .cancelled
        case .io(let code, _): .readFailed(code: code)
        }
    }

    /// `forFile` is true when one file was being read: a missing file is then that file's problem.
    static func map(_ error: any Error, forFile: Bool) -> SourceError {
        if let error = error as? SourceError { return error }
        if error is CancellationError { return .cancelled }
        if let failure = error as? StreamingFileWriter.Failure { return map(failure) }
        guard let error = error as? DestinationError else { return .unavailable }
        switch error {
        case .reauthRequired, .unauthorized: return .accessRevoked
        case .notFound: return forFile ? .fileMissing : .unavailable
        case .offline, .rateLimited, .server, .transient: return .unavailable
        case .itemRejected(let reason):
            let status = reason.split(separator: " ").dropFirst().first.flatMap { Int($0) }
            return .readFailed(code: status ?? 0)
        default: return .readFailed(code: 0)
        }
    }
}
