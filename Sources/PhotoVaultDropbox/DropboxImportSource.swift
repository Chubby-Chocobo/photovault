import Foundation
import PhotoVaultCore
import PhotoVaultDrive
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
    let index: RemoteIdIndex

    /// - Parameters:
    ///   - scratchDirectory: where `inspect` keeps the file it downloads while hashing it.
    ///   - stateDirectory: where this import keeps which Dropbox file each relative path names; created when missing.
    public init(id: SourceID, rootPath: String, client: DropboxClient, scratchDirectory: URL, stateDirectory: URL,
                metadata: any FileMetadataReading) {
        self.id = id
        self.rootPath = Self.normalizedRoot(rootPath)
        self.client = client
        self.scratchDirectory = scratchDirectory
        self.metadata = metadata
        index = RemoteIdIndex(file: stateDirectory.appendingPathComponent("remote-ids.json"))
    }

    public func probe() async throws {
        do { try await client.probeFolder(path: rootPath) } catch SourceError.fileMissing { throw SourceError.unavailable }
    }

    public func listFiles() async throws -> [FolderFileEntry] {
        let listing = try await list()
        do { return try await index.stabilize(listing.entries, paths: listing.ids) } catch {
            throw SourceError.readFailed(code: (error as NSError).code)
        }
    }

    public func inspect(relativePath: String, uti: String, mediaType: MediaType, control: ExportControl) async throws -> InspectedFile {
        let fileId = try await resolve(relativePath)
        do { try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true) } catch {
            throw SourceError.readFailed(code: (error as NSError).code)
        }
        let scratch = scratchDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try await download(fileId, to: scratch, control: control)
        return InspectedFile(size: file.size, sha256: file.sha256, metadata: metadata.fileMetadata(of: scratch, uti: uti, mediaType: mediaType))
    }

    public func exportResource(_ locator: ResourceLocator, to destination: URL, control: ExportControl) async throws -> ExportedFile {
        guard let primary = ImportLocator(localId: locator.localId), primary.sourceId == id else { throw SourceError.fileMissing }
        return try await download(resolve(primary.sibling(named: locator.originalFilename)), to: destination, control: control)
    }

    // MARK: Internals

    /// Dropbox id of a path. A path the map does not know triggers one shared listing that adds what is new.
    func resolve(_ relativePath: String) async throws -> String {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." }) else { throw SourceError.fileMissing }
        let path = relativePath.precomposedStringWithCanonicalMapping
        if let found = await index.lookup(path) { return found }
        let found: String?
        do { found = try await index.resolve(path) { try await self.list().ids } } catch let error as SourceError { throw error } catch {
            throw SourceError.unavailable
        }
        guard let found else { throw SourceError.fileMissing }
        return found
    }

    /// Files are read by id, so renames, case and Unicode form of names cannot miss them. A file that is gone while
    /// its root folder is gone too is the source being away, not that file being lost.
    private func download(_ fileId: String, to destination: URL, control: ExportControl) async throws -> ExportedFile {
        do { return try await client.download(path: fileId, to: destination, control: control) } catch SourceError.fileMissing {
            try await probe()
            throw SourceError.fileMissing
        }
    }

    struct Listing {
        var entries: [FolderFileEntry] = []
        var ids: [String: String] = [:]
    }

    /// Photos and videos under the root as the listing names them. Folder names come from the folder entries
    /// themselves: Dropbox keeps the case of `path_display` only for the last component.
    func list() async throws -> Listing {
        let entries: [DropboxListEntry]
        do { entries = try await client.listAll(path: rootPath, recursive: true) } catch SourceError.fileMissing {
            throw SourceError.unavailable
        }
        var folderNames: [String: String] = [:]
        for entry in entries where entry.tag == "folder" {
            if let lower = entry.pathLower { folderNames[lower] = entry.name }
        }
        let rootDepth = rootPath.split(separator: "/").count
        var listing = Listing()
        for entry in entries where entry.tag == "file" && entry.isDownloadable != false {
            guard let fileId = entry.id, let lower = entry.pathLower else { continue }
            let lowerParts = lower.split(separator: "/", omittingEmptySubsequences: true)
            let displayParts = entry.pathDisplay.map { $0.split(separator: "/", omittingEmptySubsequences: true).map(String.init) } ?? []
            guard lowerParts.count > rootDepth else { continue }
            var names: [String] = []
            for depth in rootDepth..<(lowerParts.count - 1) {
                let key = "/" + lowerParts[...depth].joined(separator: "/")
                names.append(folderNames[key] ?? (depth < displayParts.count ? displayParts[depth] : String(lowerParts[depth])))
            }
            names.append(entry.name)
            guard !names.contains(where: { $0.hasPrefix(".") }) else { continue }
            let relative = names.joined(separator: "/").precomposedStringWithCanonicalMapping
            guard let uti = Self.supportedType(of: relative) else { continue }
            listing.ids[relative] = fileId
            listing.entries.append(FolderFileEntry(
                relativePath: relative, uti: uti, sizeBytes: entry.size ?? 0,
                creationDate: DropboxDates.parse(entry.clientModified), modificationDate: DropboxDates.parse(entry.serverModified)))
        }
        listing.entries.sort { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
        return listing
    }

    static func normalizedRoot(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
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
