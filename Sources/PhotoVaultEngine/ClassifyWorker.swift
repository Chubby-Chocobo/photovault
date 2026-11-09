import Foundation
import PhotoVaultCore
import PhotoVaultStore

public struct ClassifyResult: Sendable, Equatable {
    public var classified = 0
    /// Provisional assets looked at in the pass (each at most once).
    public var walked = 0
    /// The guard refused new work (critical disk or staging full); retry later.
    public var blocked = false
}

/// FR-20 step 3 of the cycle: provisional photos are read just far enough to see TIFF Make/Model,
/// then the category becomes final, the destination set is recomputed both ways and the placement
/// is fixed. Every read goes through the `ResourceGuard` like an export, so watermarks, the
/// staging cap and (for non-incremental assets) the power gates and the backfill bucket apply.
actor ClassifyWorker {
    private let env: EngineEnvironment
    private let resourceGuard: ResourceGuard
    private let staging: StagingManager
    private let extensions: [any JobPlanningExtension]
    private var retryAfter: [AssetKey: Date] = [:]

    /// What the header classifier may hold in memory per read (`HeaderClassifier.maxBuffered`).
    static let headerBufferBytes: Int64 = 32 << 20

    /// A header read is small on the wire; the real size of a fully downloaded file is trued up afterwards.
    private static let estimatedBytes: Int64 = 1 << 20

    /// Bytes a header read holds against the guard's staging cap while it runs: the file size when
    /// known and smaller than the classifier's buffer, else the buffer.
    static func headerBudget(fileSize: Int64?) -> Int64 {
        max(1, min(fileSize ?? headerBufferBytes, headerBufferBytes))
    }
    private static let inconclusiveRetry: TimeInterval = 15 * 60

    init(env: EngineEnvironment, resourceGuard: ResourceGuard, staging: StagingManager, extensions: [any JobPlanningExtension] = []) {
        self.env = env
        self.resourceGuard = resourceGuard
        self.staging = staging
        self.extensions = extensions
    }

    func runPass() async throws -> ClassifyResult {
        var result = ClassifyResult()
        var cursor: EngineQueries.ProvisionalCursor?
        let batch = max(1, env.tuning.classifyBatchSize)
        while true {
            try Task.checkCancellation()
            let start = cursor
            let page = try await env.store.read { db in
                let scope = ClassifyScope(destinations: try DestinationRepository.fetchAll(db))
                return try EngineQueries.provisionalPage(db, after: start, limit: batch, scope: scope)
            }
            guard let last = page.last else { return result }
            cursor = last.cursor
            for entry in page {
                result.walked += 1
                switch try await classify(entry.key) {
                case .classified: result.classified += 1
                case .skipped: break
                case .rateLimited: return result
                case .blocked:
                    result.blocked = true
                    return result
                }
            }
        }
    }

    private enum Outcome { case classified, skipped, rateLimited, blocked }

    private struct Work: Sendable {
        var asset: AssetRecord
        var primary: ResourceRecord
        var settings: SettingsSnapshot
    }

    private func loadWork(_ key: AssetKey) async throws -> Work? {
        let snapshot = await env.settingsSnapshot()
        return try await env.store.read { db in
            guard let asset = try AssetRepository.fetch(db, key: key), asset.categoryProvisional, asset.deletedAt == nil else { return nil }
            let destinations = try DestinationRepository.fetchAll(db)
            guard Eligibility.needsClassification(asset, destinations: destinations, settings: snapshot.settings, archiveTimeZone: snapshot.timeZone)
            else { return nil }
            let resources = try ResourceRepository.fetchAll(db, key: key)
            guard let primaryType = ResourcePlanner.primary(of: resources.map(\.descriptor))?.type,
                  let primary = resources.first(where: { $0.type == primaryType }) else { return nil }
            return Work(asset: asset, primary: primary, settings: snapshot)
        }
    }

    private func classify(_ key: AssetKey) async throws -> Outcome {
        if let after = retryAfter[key], after > env.clock.now { return .skipped }
        guard let work = try await loadWork(key) else { return .skipped }
        let admission = await resourceGuard.admit(
            rateLimited: work.asset.insertedAt == nil, estimatedBytes: Self.estimatedBytes, sizeLimit: nil,
            reservedBytes: Self.headerBudget(fileSize: work.primary.sizeBytes))
        let permit: ExportPermit
        switch admission {
        case .denied(.stopAll): return .blocked
        // Everything after this asset in the order is rate limited the same way: stop the pass.
        case .denied(.rateLimited): return work.asset.insertedAt == nil ? .rateLimited : .skipped
        case .granted(let granted): permit = granted
        }
        let spill = staging.fileURL(assetKey: key, type: work.primary.type, generation: work.primary.contentGen)
        try FileManager.default.createDirectory(at: spill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: spill)
        let header: HeaderResult
        do {
            header = try await env.photos.readClassificationHeader(
                localId: work.asset.localId, type: work.primary.type, spillTo: spill, control: permit.control)
        } catch {
            await resourceGuard.finish(permit, actualBytes: nil)
            staging.remove(spill)
            if error is EngineAbort || error is CancellationError { throw error }
            env.log.log(.notice, category: "classify", "header read failed: \(error is PhotosSourceError ? "\(error)" : "other")")
            retryAfter[key] = env.clock.now.addingTimeInterval(Self.inconclusiveRetry)
            return .skipped
        }
        await resourceGuard.finish(permit, actualBytes: header.completeFile?.size)
        guard header.isConclusive else {
            if header.completeFile == nil { staging.remove(spill) }
            retryAfter[key] = env.clock.now.addingTimeInterval(Self.inconclusiveRetry)
            return .skipped
        }
        let adopted = adoptedFile(header.completeFile, at: spill)
        if header.completeFile != nil, adopted == nil { staging.remove(spill) }
        try await commit(work: work, metadata: header.metadata ?? .empty, staged: adopted)
        retryAfter[key] = nil
        return .classified
    }

    /// The complete file the header read downloaded is kept as the primary's staging (FR-20).
    private func adoptedFile(_ file: ExportedFile?, at path: URL) -> ExportedFile? {
        guard let file else { return nil }
        if file.url.standardizedFileURL == path.standardizedFileURL { return file }
        do {
            try? FileManager.default.removeItem(at: path)
            try FileManager.default.moveItem(at: file.url, to: path)
            return ExportedFile(url: path, size: file.size, md5: file.md5, sha256: file.sha256)
        } catch {
            return nil
        }
    }

    private func commit(work: Work, metadata: CaptureMetadata, staged: ExportedFile?) async throws {
        let env = env
        let extensions = extensions
        let key = work.asset.assetKey
        let primary = work.primary
        let adopted: Bool = try await env.store.write { db in
            guard var asset = try AssetRepository.fetch(db, key: key), asset.categoryProvisional else { return false }
            let context = try env.context(db, work.settings)
            let albums = try AssetRepository.albums(db, for: key).map(\.albumTitle)
            let hasRaw = try ResourceRepository.fetchAll(db, key: key).contains(where: \.isRaw)
            let result = CategoryClassifier.classify(
                mediaType: asset.mediaType, subtypes: asset.mediaSubtypes, hasRaw: hasRaw, albumTitles: albums,
                settings: context.settings, headerMetadata: metadata)
            asset.category = result.category
            asset.categoryReason = result.reason
            asset.categoryProvisional = result.provisional
            asset.cameraMake = metadata.make ?? asset.cameraMake
            asset.cameraModel = metadata.model ?? asset.cameraModel
            asset.lensModel = metadata.lensModel ?? asset.lensModel
            try AssetRepository.upsert(db, asset, timeZone: context.timeZone)
            var kept = false
            if let staged, try ResourceRepository.beginExport(db, key: key, type: primary.type, generation: primary.contentGen) {
                kept = try ResourceRepository.completeExport(
                    db, key: key, type: primary.type, path: staged.url.path, sizeBytes: staged.size,
                    md5: staged.md5, sha256: staged.sha256, now: context.now)
            }
            var dirty = Set<ArchiveDay>()
            if let creation = asset.creationDate { dirty.insert(ArchiveDay(date: creation, timeZone: context.timeZone)) }
            try AssetFinalizer.finalize(db, key: key, context: context, dirtyDays: &dirty, extensions: extensions)
            try AssetFinalizer.recount(db, days: dirty, context: context)
            return kept
        }
        if let staged, !adopted { staging.remove(staged.url) }
    }
}
