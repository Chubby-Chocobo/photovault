import Foundation

/// Names one resource of an asset in its source.
public struct ResourceLocator: Hashable, Sendable {
    public var sourceId: SourceID
    public var localId: String
    public var type: ResourceType
    public var originalFilename: String

    public init(sourceId: SourceID, localId: String, type: ResourceType, originalFilename: String) {
        self.sourceId = sourceId
        self.localId = localId
        self.type = type
        self.originalFilename = originalFilename
    }
}

/// Reads the bytes of resources for export. Errors are `PhotosSourceError` (Photos) or `SourceError`.
public protocol ContentSource: Sendable {
    var id: SourceID { get }
    func exportResource(_ locator: ResourceLocator, to destination: URL, control: ExportControl) async throws -> ExportedFile
}

/// A file found by listing a folder.
public struct FolderFileEntry: Hashable, Sendable {
    public var relativePath: String
    public var uti: String
    public var sizeBytes: Int64
    public var creationDate: Date?
    public var modificationDate: Date?

    public init(relativePath: String, uti: String, sizeBytes: Int64, creationDate: Date? = nil, modificationDate: Date? = nil) {
        self.relativePath = relativePath
        self.uti = uti
        self.sizeBytes = sizeBytes
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }
}

/// What a file's own metadata says. Missing values are nil, never errors.
public struct FileMetadata: Hashable, Sendable {
    public var capture: CaptureMetadata
    /// Creation date of a video (QuickTime); images leave it nil.
    public var captureDate: Date?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var duration: Double
    public var location: GeoPoint?
    public var isScreenshot: Bool
    /// Apple content identifier that ties a Live Photo's image to its video.
    public var contentIdentifier: String?

    public init(capture: CaptureMetadata = .empty, captureDate: Date? = nil, pixelWidth: Int = 0, pixelHeight: Int = 0,
                duration: Double = 0, location: GeoPoint? = nil, isScreenshot: Bool = false, contentIdentifier: String? = nil) {
        self.capture = capture
        self.captureDate = captureDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.location = location
        self.isScreenshot = isScreenshot
        self.contentIdentifier = contentIdentifier
    }

    public static let empty = FileMetadata()
}

/// A file's size, SHA-256 and metadata, read in one pass.
public struct InspectedFile: Hashable, Sendable {
    public var size: Int64
    public var sha256: String
    public var metadata: FileMetadata

    public init(size: Int64, sha256: String, metadata: FileMetadata) {
        self.size = size
        self.sha256 = sha256
        self.metadata = metadata
    }
}

/// A folder the owner picked, imported once.
public protocol FolderImportSource: ContentSource {
    /// Throws `SourceError.unavailable` when the folder cannot be read now.
    func probe() async throws
    func listFiles() async throws -> [FolderFileEntry]
    func inspect(relativePath: String, uti: String, mediaType: MediaType, control: ExportControl) async throws -> InspectedFile
}

/// Reads metadata from a file on disk (FR-34 for imports).
public protocol FileMetadataReading: Sendable {
    func fileMetadata(of file: URL, uti: String, mediaType: MediaType) -> FileMetadata
}
