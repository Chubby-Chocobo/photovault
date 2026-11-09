import Foundation
import GRDB
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// A cloud group that keeps failing is given up as a whole, after a day and ten tries, and only while it is really tried.
@Suite struct CloudImportGiveUpTests {
    private func harness() async throws -> Harness {
        let h = try await Harness()
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

    private func step(_ h: Harness, hours: Double, times: Int) async {
        for _ in 0..<times { h.clock.advance(by: hours * 3600); await h.settle(rounds: 3) }
    }

    @Test func twoShortRefusalsMoreThanADayApartDoNotFailTheFile() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try photos(h, ["a.jpg", "b.jpg"]))
        source.setFailure(path: "a.jpg", SourceError.busy)
        let id = try await h.startCloudImport(source)
        source.setFailure(path: "a.jpg", nil)
        source.setFailure(.probe, SourceError.unavailable)
        await step(h, hours: 0.01, times: 1)
        #expect(try h.source(id)?.status == .offline)
        await step(h, hours: 6, times: 5)
        source.setFailure(.probe, nil)
        source.failOnce(.inspect, SourceError.busy)
        await step(h, hours: 0.01, times: 1)
        await step(h, hours: 0.05, times: 4)
        #expect(try h.importCounts(id) == [.imported: 2])
    }

    @Test func aPairOfFilesIsGivenUpTogetherWithinAboutADay() async throws {
        let h = try await harness()
        let folder = try ImportFolder()
        try folder.add("x.jpg", metadata: ImportFolder.photo(at: h.clock.now.addingTimeInterval(-3 * 86_400)))
        try folder.add("x.mov", "movie-bytes")
        let source = FakeCloudSource(folder)
        source.setFailure(path: "x.jpg", SourceError.busy)
        source.setFailure(path: "x.mov", SourceError.busy)
        let id = try await h.startCloudImport(source)
        await step(h, hours: 1, times: 20)
        #expect(try h.importCounts(id) == [.pending: 2], "still waiting before a day has passed")
        await step(h, hours: 1, times: 8)
        #expect(try h.importCounts(id) == [.failed: 2])
        #expect(try h.source(id)?.status == .completed)
    }

    @Test func aProviderThatRefusesEverythingOnlyCostsTheGroupsActuallyTried() async throws {
        let h = try await harness()
        let source = FakeCloudSource(try photos(h, ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg"]))
        source.setFailure(.inspect, SourceError.busy)
        let id = try await h.startCloudImport(source)
        await step(h, hours: 1, times: 26)
        let counts = try h.importCounts(id)
        #expect((counts[.failed] ?? 0) <= 3, "\(counts)")
        #expect((counts[.pending] ?? 0) >= 2 && counts[.imported] == nil, "\(counts)")

        source.setFailure(.inspect, nil)
        await step(h, hours: 0.05, times: 6)
        #expect(try h.importCounts(id)[.pending] == nil)
        #expect(try h.importCounts(id)[.imported] == 2)
    }
}
