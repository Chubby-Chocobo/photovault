import Foundation
import PhotoVaultCore
import UniformTypeIdentifiers

/// A Dropbox folder (or the whole account) read once to import its photos. Read-only: nothing here
/// uploads, moves or deletes. Errors are `SourceError`.
public struct DropboxImportSource: FolderImportSource {
    public let id: SourceID
    /// `""` for the whole account, otherwise `/x/y` with no trailing slash.
    let rootPath: String
    let client: DropboxClient
    let scratchDirectory: URL
    let metadata: any FileMetadataReading

    /// - Parameter scratchDirectory: where `inspect` keeps the file it downloads while hashing it.
    public init(id: SourceID, rootPath: String, client: DropboxClient, scratchDirectory: URL, metadata: any FileMetadataReading) {
        self.id = id
        self.rootPath = Self.normalizedRoot(rootPath)
        self.client = client
        self.scratchDirectory = scratchDirectory
        self.metadata = metadata
    }

    public func probe() async throws {
        do { try await client.probeFolder(path: rootPath) } catch SourceError.fileMissing { throw SourceError.unavailable }
    }

    public func listFiles() async throws -> [FolderFileEntry] {
        let entries: [DropboxListEntry]
        do { entries = try await client.listAll(path: rootPath, recursive: true) } catch SourceError.fileMissing {
            throw SourceError.unavailable
        }
        let rootDepth = rootPath.split(separator: "/").count
        var files: [FolderFileEntry] = []
        for entry in entries where entry.tag == "file" && entry.isDownloadable != false {
            guard let display = entry.pathDisplay else { continue }
            let parts = display.split(separator: "/").dropFirst(rootDepth)
            guard !parts.isEmpty, !parts.contains(where: { $0.hasPrefix(".") }) else { continue }
            let relative = parts.joined(separator: "/").precomposedStringWithCanonicalMapping
            guard let uti = Self.supportedType(of: relative) else { continue }
            files.append(FolderFileEntry(
                relativePath: relative, uti: uti, sizeBytes: entry.size ?? 0,
                creationDate: DropboxDates.parse(entry.clientModified), modificationDate: DropboxDates.parse(entry.serverModified)))
        }
        return files.sorted { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
    }

    public func inspect(relativePath: String, uti: String, mediaType: MediaType, control: ExportControl) async throws -> InspectedFile {
        let remote = try remotePath(relativePath)
        do { try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true) } catch {
            throw SourceError.readFailed(code: (error as NSError).code)
        }
        let scratch = scratchDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try await client.download(path: remote, to: scratch, control: control)
        return InspectedFile(size: file.size, sha256: file.sha256, metadata: metadata.fileMetadata(of: scratch, uti: uti, mediaType: mediaType))
    }

    public func exportResource(_ locator: ResourceLocator, to destination: URL, control: ExportControl) async throws -> ExportedFile {
        guard let primary = ImportLocator(localId: locator.localId), primary.sourceId == id else { throw SourceError.fileMissing }
        return try await client.download(path: remotePath(primary.sibling(named: locator.originalFilename)), to: destination, control: control)
    }

    // MARK: Paths

    static func normalizedRoot(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
    }

    /// Dropbox path of a file; a relative path that climbs out of the root names nothing.
    func remotePath(_ relativePath: String) throws -> String {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." }) else { throw SourceError.fileMissing }
        return rootPath + "/" + relativePath
    }

    /// UTI for photos, videos (RAW included) and the ignored sidecar extensions; nil for anything else.
    static func supportedType(of path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        let ignored = FolderItemGrouper.ignoredExtensions.contains(ext)
        guard let type = UTType(filenameExtension: ext) ?? (ignored ? UTType.data : nil) else { return nil }
        if type.conforms(to: .image) || type.conforms(to: .movie) { return type.identifier }
        return ignored ? type.identifier : nil
    }
}
