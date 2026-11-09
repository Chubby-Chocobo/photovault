import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// Files that keep failing never keep the rest of a cloud import from being read, and are all given up in the end.
@Suite struct CloudImportStubbornFilesTests {
    private func harness(batch: Int? = nil) async throws -> Harness {
        let h = try await Harness { if let batch { $0.importBatchGroups = batch } }
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        return h
    }

    private func photos(_ h: Harness, _ names: [String]) throws -> ImportFolder {
        let folder = try ImportFolder()
        let when = h.clock.now.addingTimeInterval(-3 * 86_400)
        for (index, name) in names.enumerated() {
            try folder.add(name, metadata: ImportFolder.photo(at: when.addingTimeInterval(Double(-index) * 3600)))
        }
        return folder
    }

    /// The five-minute recheck of an import that is still reading.
    private func run(_ h: Harness, hours: Double) async {
        for _ in 0..<Int(hours * 12) { h.clock.advance(by: 300); await h.settle(rounds: 3) }
    }

    @Test func twoStubbornFilesAtTheEndAreBothGivenUp() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try photos(h, ["a.jpg", "b.jpg", "c.jpg"]))
        source.setFailure(path: "a.jpg", SourceError.busy)
        source.setFailure(path: "b.jpg", SourceError.busy)
        let id = try await h.startCloudImport(source)
        await run(h, hours: 30)
        #expect(try h.importCounts(id) == [.imported: 1, .failed: 2])
        #expect(try h.source(id)?.status == .completed)
    }

    @Test func threeStubbornFilesAtTheHeadDoNotHoldBackTheRest() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try photos(h, ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg"]))
        for name in ["a.jpg", "b.jpg", "c.jpg"] { source.setFailure(path: name, SourceError.busy) }
        let id = try await h.startCloudImport(source)
        await run(h, hours: 1)
        #expect(try h.importCounts(id)[.imported] == 2, "the readable files are read within the first hour")
        await run(h, hours: 29)
        #expect(try h.importCounts(id) == [.imported: 2, .failed: 3])
        #expect(try h.source(id)?.status == .completed)
    }

    @Test func droppedConnectionsOnThreeFilesAreTreatedTheSame() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try photos(h, ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]))
        for name in ["a.jpg", "b.jpg", "c.jpg"] { source.setFailure(path: name, SourceError.unavailable) }
        let id = try await h.startCloudImport(source)
        await run(h, hours: 30)
        #expect(try h.importCounts(id) == [.imported: 1, .failed: 3])
    }

    @Test func threeStubbornFilesInTheMiddleAreGivenUpAndTheRestImports() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try photos(h, ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg", "f.jpg"]))
        for name in ["b.jpg", "c.jpg", "d.jpg"] { source.setFailure(path: name, SourceError.busy) }
        let id = try await h.startCloudImport(source)
        await run(h, hours: 30)
        #expect(try h.importCounts(id) == [.imported: 3, .failed: 3])
    }

    @Test func aLoneStubbornFileIsGivenUpEvenWhenTheMacSleptInBetween() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try photos(h, ["a.jpg", "b.jpg"]))
        source.setFailure(path: "a.jpg", SourceError.busy)
        let id = try await h.startCloudImport(source)
        await run(h, hours: 1)
        h.clock.advance(by: 3 * 3600)
        await h.settle(rounds: 3)
        await run(h, hours: 48)
        #expect(try h.importCounts(id) == [.imported: 1, .failed: 1])
        #expect(try h.source(id)?.status == .completed)
    }

    @Test func stubbornFilesSpreadOverALargeImportNeverStopTheRest() async throws {
        let h = try await harness(batch: 20)
        let folder = try ImportFolder()
        let when = h.clock.now.addingTimeInterval(-3 * 86_400)
        for index in 0..<120 {
            try folder.add(String(format: "p%03d.jpg", index), metadata: ImportFolder.photo(at: when.addingTimeInterval(Double(-index) * 60)))
        }
        let fake = FakeCloudSource(folder)
        for index in [5, 30, 55] { fake.setFailure(path: String(format: "p%03d.jpg", index), SourceError.busy) }
        let clock = h.clock
        let id = try await h.startCloudImport(SlowCloudSource(fake) { clock.advance(by: 2) })
        await run(h, hours: 30)
        #expect(try h.importCounts(id) == [.imported: 117, .failed: 3])
        #expect(try h.source(id)?.status == .completed)
    }

    @Test func anOutageWhereTheProviderDoesNotAnswerFailsNothing() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try photos(h, ["a.jpg", "b.jpg", "c.jpg"]))
        let id = try await h.startCloudImport(source)
        source.setFailure(.probe, SourceError.unavailable)
        source.setFailure(.inspect, SourceError.unavailable)
        // A file read is attempted once before the outage reaches the probe.
        await run(h, hours: 72)
        #expect(try h.importCounts(id)[.failed] == nil)
        source.setFailure(.probe, nil)
        source.setFailure(.inspect, nil)
        await run(h, hours: 1)
        #expect(try h.importCounts(id)[.failed] == nil)
        #expect(try h.source(id)?.status == .completed)
    }
}
