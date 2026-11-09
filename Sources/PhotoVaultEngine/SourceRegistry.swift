import Foundation
import PhotoVaultCore

/// Live content sources by id. Photos is always present; folder imports are added while the engine runs.
public actor SourceRegistry {
    private var map: [SourceID: any ContentSource] = [:]

    public init(photos: any PhotosSource) {
        map[.photos] = PhotosContentSource(photos: photos)
    }

    public func add(_ source: any ContentSource) { if source.id != .photos { map[source.id] = source } }
    public func remove(_ id: SourceID) { if id != .photos { map[id] = nil } }
    public func content(for id: SourceID) -> (any ContentSource)? { map[id] }
    public func folder(for id: SourceID) -> (any FolderImportSource)? { map[id] as? any FolderImportSource }
    public var ids: [SourceID] { map.keys.sorted() }
}

/// Reads Photos resources through the common content-source contract.
struct PhotosContentSource: ContentSource {
    let photos: any PhotosSource
    var id: SourceID { .photos }

    func exportResource(_ locator: ResourceLocator, to destination: URL, control: ExportControl) async throws -> ExportedFile {
        try await photos.exportResource(localId: locator.localId, type: locator.type, to: destination, control: control)
    }
}
