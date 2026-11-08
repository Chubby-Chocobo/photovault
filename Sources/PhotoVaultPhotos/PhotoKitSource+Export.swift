import Foundation
import PhotoVaultCore

extension PhotoKitSource {
    public func exportResource(
        localId: String, type: ResourceType, to destination: URL, control: ExportControl
    ) async throws -> ExportedFile {
        try requireAccess()
        let writer: StreamingFileWriter
        do {
            writer = try StreamingFileWriter(url: destination, control: control)
        } catch let failure as StreamingFileWriter.Failure {
            throw PhotosErrorMapper.map(failure)
        }
        do {
            try await stream(localId: localId, type: type) { writer.append($0) }
            return try writer.finish()
        } catch {
            let writerFailure = writer.failure
            writer.abort()
            if let writerFailure { throw PhotosErrorMapper.map(writerFailure) }
            if control.isCancelled { throw PhotosSourceError.cancelled }
            throw PhotosErrorMapper.map(error)
        }
    }

    public func readClassificationHeader(
        localId: String, type: ResourceType, spillTo: URL, control: ExportControl
    ) async throws -> HeaderResult {
        try requireAccess()
        let writer: StreamingFileWriter
        do {
            writer = try StreamingFileWriter(url: spillTo, control: control)
        } catch let failure as StreamingFileWriter.Failure {
            throw PhotosErrorMapper.map(failure)
        }
        let classifier = HeaderClassifierBox()
        do {
            try await stream(localId: localId, type: type) { data in
                guard writer.append(data) else { return false }
                return !classifier.append(data)
            }
        } catch {
            let writerFailure = writer.failure
            writer.abort()
            if let writerFailure { throw PhotosErrorMapper.map(writerFailure) }
            if control.isCancelled { throw PhotosSourceError.cancelled }
            // Stopping the request because the answer is known surfaces as a PhotoKit error.
            if case .present(let metadata) = classifier.outcome { return Self.conclusive(metadata) }
            if case .absent(let metadata) = classifier.outcome { return Self.conclusive(metadata) }
            throw PhotosErrorMapper.map(error)
        }
        if classifier.stoppedEarly {
            // Completed without error after we stopped: the file may be truncated, so do not keep it.
            writer.abort()
            switch classifier.outcome {
            case .present(let metadata), .absent(let metadata): return Self.conclusive(metadata)
            default: return HeaderResult(metadata: nil, isConclusive: false, completeFile: nil)
            }
        }
        let outcome = classifier.finish()
        let file = try? writer.finish()
        if file == nil { writer.abort() }
        if classifier.overflowed, let file {
            // Too large to classify in memory: read the properties from the complete file instead.
            return HeaderResult(metadata: ImageIOMetadataReader.imageMetadata(of: file.url), isConclusive: true, completeFile: file)
        }
        switch outcome {
        case .present(let metadata), .absent(let metadata):
            return HeaderResult(metadata: metadata, isConclusive: true, completeFile: file)
        case .needMore, .undecidable:
            return HeaderResult(metadata: nil, isConclusive: false, completeFile: file)
        }
    }

    public func adjustmentDataHash(localId: String) async throws -> String? {
        try requireAccess()
        guard try Self.resource(localId: localId, type: .adjustmentData) != nil else { return nil }
        let hasher = StreamingSHA256()
        do {
            try await stream(localId: localId, type: .adjustmentData) { hasher.append($0); return true }
        } catch {
            throw PhotosErrorMapper.map(error)
        }
        return hasher.hexDigest()
    }

    private static func conclusive(_ metadata: CaptureMetadata) -> HeaderResult {
        HeaderResult(metadata: metadata, isConclusive: true, completeFile: nil)
    }
}
