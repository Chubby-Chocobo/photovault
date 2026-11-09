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
    let index: RemoteIdIndex

    /// - Parameters:
    ///   - pickedIds: Drive ids the owner picked.
    ///   - scratchDirectory: where `inspect` puts its temporary copy; created when missing.
    ///   - stateDirectory: where this import keeps which Drive file each relative path names; created when missing.
    public init(id: SourceID, pickedIds: [String], auth: any DriveAuthorizing, transport: any HTTPTransport,
                scratchDirectory: URL, stateDirectory: URL, metadata: any FileMetadataReading) {
        self.id = id
        http = DriveHTTP(transport: transport, auth: auth)
        lister = DriveImportLister(http: http, pickedIds: pickedIds)
        self.metadata = metadata
        self.scratchDirectory = scratchDirectory
        index = RemoteIdIndex(file: stateDirectory.appendingPathComponent("remote-ids.json"))
    }

    public func probe() async throws {
        guard let first = lister.pickedIds.first else { throw SourceError.unavailable }
        do { _ = try await lister.item(first) } catch {
            // A picked item that was deleted or is no longer shared still means Drive answered.
            if DriveImportLister.isPerItem(error) { return }
            throw Self.map(error, forFile: false)
        }
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
        let listing: DriveImportLister.Listing
        do { listing = try await lister.list() } catch { throw Self.map(error, forFile: false) }
        do { return try await index.stabilize(listing.entries, paths: listing.ids) } catch {
            throw SourceError.readFailed(code: (error as NSError).code)
        }
    }

    public func inspect(relativePath: String, uti: String, mediaType: MediaType, control: ExportControl) async throws -> InspectedFile {
        let fileId = try await resolve(relativePath)
        do { try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true) } catch {
            throw SourceError.readFailed(code: (error as NSError).code)
        }
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

    /// Drive id of a path. A path the map does not know triggers one shared listing that adds what is new.
    func resolve(_ relativePath: String) async throws -> String {
        let path = relativePath.precomposedStringWithCanonicalMapping
        if let found = await index.lookup(path) { return found }
        let lister = lister
        let found: String?
        do { found = try await index.resolve(path) { try await lister.list().ids } } catch {
            throw Self.map(error, forFile: false)
        }
        guard let found else { throw SourceError.fileMissing }
        return found
    }

    private func download(_ fileId: String, to url: URL, control: ExportControl) async throws -> ExportedFile {
        let writer: StreamingFileWriter
        do { writer = try StreamingFileWriter(url: url, control: control) } catch let failure as StreamingFileWriter.Failure {
            throw Self.map(failure)
        }
        let media = DriveURL.make(DriveURL.api, "/files/" + FormEncoding.escape(fileId), [("alt", "media"), ("supportsAllDrives", "true")])
        do {
            try await http.download(media) { chunk in
                if !writer.append(chunk) { throw writer.failure.map(Self.map) ?? SourceError.cancelled }
            }
            try Task.checkCancellation()
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
    /// Only `SourceError` and `CancellationError` leave the adapter.
    static func map(_ error: any Error, forFile: Bool) -> SourceError {
        if let error = error as? SourceError { return error }
        if error is CancellationError { return .cancelled }
        if let failure = error as? StreamingFileWriter.Failure { return map(failure) }
        guard let error = error as? DestinationError else { return .unavailable }
        switch error {
        case .reauthRequired, .unauthorized: return .accessRevoked
        case .notFound: return forFile ? .fileMissing : .unavailable
        case .offline: return .unavailable
        case .rateLimited, .server, .transient: return .busy
        case .itemRejected(let reason):
            let status = reason.split(separator: " ").dropFirst().first.flatMap { Int($0) }
            return .readFailed(code: status ?? 0)
        default: return .readFailed(code: 0)
        }
    }
}
