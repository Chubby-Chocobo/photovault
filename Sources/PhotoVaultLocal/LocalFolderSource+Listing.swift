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
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
        ]
        let base = folder.standardizedFileURL
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true })
        else { throw SourceError.unavailable }
        var entries: [FolderFileEntry] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            let hidden = name.hasPrefix(".")
            // Hidden entries are skipped, except the placeholders iCloud Drive leaves for files it has not downloaded.
            if hidden, !name.hasSuffix(".icloud") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { walker.skipDescendants() }
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                if values.isPackage == true || libraryExtensions.contains(url.pathExtension.lowercased()) { walker.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, let uti = supportedType(of: url) else { continue }
            let prefix = base.path + "/"
            guard url.standardizedFileURL.path.hasPrefix(prefix) else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(prefix.count)).precomposedStringWithCanonicalMapping
            entries.append(FolderFileEntry(
                relativePath: relative, uti: uti, sizeBytes: Int64(values.fileSize ?? 0),
                creationDate: values.creationDate, modificationDate: values.contentModificationDate))
        }
        return entries.sorted { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
    }

    /// UTI for photos, videos (RAW included) and the ignored sidecar extensions; nil for anything else.
    static func supportedType(of url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        guard let type = UTType(filenameExtension: ext) ?? (FolderItemGrouper.ignoredExtensions.contains(ext) ? UTType.data : nil) else { return nil }
        if type.conforms(to: .image) || type.conforms(to: .movie) { return type.identifier }
        return FolderItemGrouper.ignoredExtensions.contains(ext) ? type.identifier : nil
    }
}
