import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Day-folder promotion (spec 8.7). A day with more than N `camera` assets gets its own folder,
/// once and for good. In the same transaction every file of that day that is already `done` gets a
/// `move_job` at every destination (originals, edited, sidecars); files still in flight are caught
/// by the layout comparison of the `uploading → done` transaction.
enum DayFolderPromoter {
    /// Promotes `day` when its count crossed the threshold for the first time.
    @discardableResult
    static func promoteIfNeeded(_ db: Database, day: ArchiveDay, context: PipelineContext) throws -> Bool {
        guard let stat = try DayStatRepository.fetch(db, day: day), !stat.promoted,
              stat.count > context.settings.dayFolderThreshold else { return false }
        return try promote(db, day: day, context: context)
    }

    @discardableResult
    static func promote(_ db: Database, day: ArchiveDay, context: PipelineContext) throws -> Bool {
        guard try DayStatRepository.promote(db, day: day, now: context.now) else { return false }
        try enqueueMoves(db, day: day, context: context)
        try DirtyQueue.mark(db, [.place], id: day.description)
        return true
    }

    /// Move jobs for the done files of `day` that are not in the day folder yet. Returns how many
    /// were queued (the number "Sắp xếp lại" reports).
    @discardableResult
    static func enqueueMoves(_ db: Database, day: ArchiveDay, context: PipelineContext) throws -> Int {
        var queued = 0
        for key in try OrganizationQueries.cameraAssetKeys(db, day: day) {
            guard let asset = try AssetRepository.fetch(db, key: key), let placement = asset.placement else { continue }
            let target = LayoutResolver.parentLogical(try LayoutResolver.chain(db, placement: placement, layout: context.layout))
            for job in try JobRepository.fetchAll(db, assetKey: key) where job.state == .done {
                guard let from = job.remoteLogicalParent else { continue }
                if try MoveJobPlanner.enqueueMove(db, identity: job.identity, from: from, to: target, now: context.now) { queued += 1 }
            }
        }
        return queued
    }
}

/// What "Sắp xếp lại" would do with the current N.
public struct ResortPreview: Sendable, Equatable {
    /// Days that would get their own folder.
    public var days: Int
    /// Files that would be moved (one per done file at each destination).
    public var files: Int
}

/// "Sắp xếp lại" (spec 8.7 step 6): applies the current N to days that are not promoted yet. It
/// never demotes. `preview` reports the number of files first (T10); `apply` returns the same number.
struct ResortService: Sendable {
    let env: EngineEnvironment

    func preview() async throws -> ResortPreview {
        let snapshot = await env.settingsSnapshot()
        let env = env
        return try await env.store.read { db in
            let context = try env.context(db, snapshot)
            var preview = ResortPreview(days: 0, files: 0)
            for day in try Self.candidateDays(db, threshold: context.settings.dayFolderThreshold) {
                preview.days += 1
                for key in try OrganizationQueries.cameraAssetKeys(db, day: day) {
                    preview.files += try JobRepository.fetchAll(db, assetKey: key).filter { $0.state == .done }.count
                }
            }
            return preview
        }
    }

    @discardableResult
    func apply() async throws -> ResortPreview {
        let snapshot = await env.settingsSnapshot()
        let env = env
        return try await env.store.write { db in
            let context = try env.context(db, snapshot)
            var result = ResortPreview(days: 0, files: 0)
            for day in try Self.candidateDays(db, threshold: context.settings.dayFolderThreshold) {
                guard try DayStatRepository.promote(db, day: day, now: context.now) else { continue }
                try DirtyQueue.mark(db, [.place], id: day.description)
                result.days += 1
                result.files += try DayFolderPromoter.enqueueMoves(db, day: day, context: context)
            }
            return result
        }
    }

    private static func candidateDays(_ db: Database, threshold: Int) throws -> [ArchiveDay] {
        try String.fetchAll(db, sql: "SELECT day FROM day_stat WHERE promoted = 0 AND count > ? ORDER BY day", arguments: [threshold])
            .compactMap(ArchiveDay.init(string:))
    }
}
