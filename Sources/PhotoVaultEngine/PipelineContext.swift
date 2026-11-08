import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore

/// Inputs shared by every in-transaction step (ingest, placement, eligibility).
struct PipelineContext: Sendable {
    var settings: GlobalSettings
    var timeZone: TimeZone
    var destinations: [DestinationRecord]
    var now: Date
    var nameBuilder: NameStemBuilder
    var layout: any LayoutPolicy

    /// Reads the destinations inside the caller's transaction.
    init(_ db: Database, snapshot: SettingsSnapshot, now: Date, utiResolver: any UTIResolver,
         layout: any LayoutPolicy = DynamicLayout()) throws {
        self.layout = layout
        settings = snapshot.settings
        timeZone = snapshot.timeZone
        destinations = try DestinationRepository.fetchAll(db)
        self.now = now
        nameBuilder = NameStemBuilder(timeZone: snapshot.timeZone, utiResolver: utiResolver)
    }
}

extension ResourceRecord {
    var descriptor: ResourceDescriptor {
        ResourceDescriptor(type: type, uti: uti, originalFilename: originalFilename, isRaw: isRaw)
    }
}

extension EngineEnvironment {
    func settingsSnapshot() async -> SettingsSnapshot { await settings.snapshot() }

    func context(_ db: Database, _ snapshot: SettingsSnapshot) throws -> PipelineContext {
        try PipelineContext(db, snapshot: snapshot, now: clock.now, utiResolver: utiResolver, layout: layout)
    }

    func logJob(_ level: LogLevel, _ category: String, jobId: Int64?, _ message: String) {
        log.log(level, category: category, "job=\(jobId.map(String.init) ?? "-") \(message)")
    }
}
