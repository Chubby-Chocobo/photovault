import Foundation
import os
import Photos
import PhotoVaultCore

/// One `PHAssetResourceManager.requestData` call with race-free cancellation.
///
/// The request ID is only known after `requestData` returns, while the data handler may already be
/// running; a cancel that arrives in between is replayed once the ID is stored.
final class ResourceRequestSession: @unchecked Sendable {
    private struct State {
        var requestID: PHAssetResourceDataRequestID?
        var cancelRequested = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func cancel() {
        let id = state.withLock { s -> PHAssetResourceDataRequestID? in
            s.cancelRequested = true
            return s.requestID
        }
        if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
    }

    /// Starts the request. `onChunk` runs inline on PhotoKit's callback queue, in order; returning
    /// `false` cancels the request. `completion` runs once with PhotoKit's error, if any.
    func start(
        resource: PHAssetResource,
        onChunk: @escaping @Sendable (Data) -> Bool,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let id = PHAssetResourceManager.default().requestData(
            for: resource,
            options: options,
            dataReceivedHandler: { [self] data in
                if !onChunk(data) { cancel() }
            },
            completionHandler: { error in completion(error) }
        )
        let replay = state.withLock { s -> Bool in
            s.requestID = id
            return s.cancelRequested
        }
        if replay { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
}

extension PhotoKitSource {
    /// Streams one resource through `onChunk`; throws what PhotoKit reports, or `.cancelled` when the
    /// surrounding task is cancelled. Returns normally when PhotoKit completed without error.
    func stream(
        localId: String,
        type: ResourceType,
        onChunk: @escaping @Sendable (Data) -> Bool
    ) async throws {
        let session = ResourceRequestSession()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                do {
                    guard let resource = try Self.resource(localId: localId, type: type) else {
                        throw PhotosSourceError.resourceNotFound(localId: localId, type: type)
                    }
                    session.start(resource: resource, onChunk: onChunk) { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            session.cancel()
        }
    }

    /// The asset's resource of `type`; nil when the asset has none. Throws `.assetNotFound`.
    static func resource(localId: String, type: ResourceType) throws -> PHAssetResource? {
        let asset = try fetchAsset(localId: localId)
        return PHAssetResource.assetResources(for: asset).first { $0.type.rawValue == type.rawValue }
    }

    static func fetchAsset(localId: String) throws -> PHAsset {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: fetchOptions())
        guard let asset = result.firstObject else { throw PhotosSourceError.assetNotFound(localId: localId) }
        return asset
    }

    static func fetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        return options
    }
}
