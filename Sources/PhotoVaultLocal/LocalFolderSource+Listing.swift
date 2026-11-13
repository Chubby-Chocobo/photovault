import Foundation
import PhotoVaultCore
import UniformTypeIdentifiers

extension LocalFolderSource {
    /// Folders that hold a library, not photos: never entered.
    static let libraryExtensions: Set<String> = ["photoslibrary", "aplibrary", "migratedphotolibrary"]

    /// Every photo and video under the folder, plus the sidecar files that belong to them (so they can
    /// be counted as skipped, iCloud placeholders included). Other hidden files, packages and symbolic links are left out.
    public func listFiles() async throws -> [FolderFileEntry] {
        let root = root
        return try await queue.run { try Self.withFolder(root) { try Self.list($0) } }
    }

    static func list(_ folder: URL) throws -> [FolderFileEntry] {
        let base = folder.standardizedFileURL
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: listingKeys, options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true })
        else { throw SourceError.unavailable }
        var entries: [FolderFileEntry] = []
        // One pool per item: the enumerator's URLs and resource values are autoreleased, and a whole folder
        // of them would otherwise stay in memory until the listing returns.
        var more = true
        while more {
            more = autoreleasepool {
                guard let url = walker.nextObject() as? URL else { return false }
                if let entry = entry(url, base: base, walker: walker) { entries.append(entry) }
                return true
            }
        }
        return entries.sorted { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
    }

    private static let listingKeys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
    ]

    /// The listing entry for one enumerated item; nil for folders, hidden files, links and unsupported types.
    private static func entry(_ url: URL, base: URL, walker: FileManager.DirectoryEnumerator) -> FolderFileEntry? {
        let name = url.lastPathComponent
        let hidden = name.hasPrefix(".")
        // Hidden entries are skipped, except the placeholders iCloud Drive leaves for files it has not downloaded.
        if hidden, !name.hasSuffix(".icloud") {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { walker.skipDescendants() }
            return nil
        }
        guard let values = try? url.resourceValues(forKeys: Set(listingKeys)) else { return nil }
        if values.isSymbolicLink == true { return nil }
        if values.isDirectory == true {
            if values.isPackage == true || libraryExtensions.contains(url.pathExtension.lowercased()) { walker.skipDescendants() }
            return nil
        }
        guard values.isRegularFile == true, let uti = supportedType(of: url) else { return nil }
        let prefix = base.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(prefix) else { return nil }
        let relative = String(url.standardizedFileURL.path.dropFirst(prefix.count)).precomposedStringWithCanonicalMapping
        return FolderFileEntry(
            relativePath: relative, uti: uti, sizeBytes: Int64(values.fileSize ?? 0),
            creationDate: values.creationDate, modificationDate: values.contentModificationDate)
    }

    /// UTI for photos, videos (RAW included) and the ignored sidecar extensions; nil for anything else.
    static func supportedType(of url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        guard let type = UTType(filenameExtension: ext) ?? (FolderItemGrouper.ignoredExtensions.contains(ext) ? UTType.data : nil) else { return nil }
        if type.conforms(to: .image) || type.conforms(to: .movie) { return type.identifier }
        return FolderItemGrouper.ignoredExtensions.contains(ext) ? type.identifier : nil
    }
}
