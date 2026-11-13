import Darwin
import Foundation
import PhotoVaultCore
import PhotoVaultDrive
import PhotoVaultLocal
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

/// Opt-in memory benchmark: backs up and imports a few hundred MB of generated files through the real engine,
/// a real on-disk database, a real local folder destination and the app's Drive uploader over `URLSession`, and
/// prints the process footprint before, at its peak and after. Run one scenario per process, for example:
///
///     PHOTOVAULT_MEMORY_BENCH=1 swift test --filter MemoryBenchmarkTests/photosBackup
///
/// `PHOTOVAULT_MEMORY_BENCH_MB` sets the fixture size (default 300). Everything is written to a temporary folder
/// that is deleted afterwards. Nothing is asserted about the numbers: CI runners differ too much.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PHOTOVAULT_MEMORY_BENCH"] != nil))
struct MemoryBenchmarkTests {
    private var megabytes: Int { Int(ProcessInfo.processInfo.environment["PHOTOVAULT_MEMORY_BENCH_MB"] ?? "") ?? 300 }

    @Test func photosBackup() async throws {
        try await run("photos-backup") { h, base in
            let fixtures = try BenchmarkFixtures(in: base.appendingPathComponent("fixtures/Bench"), totalMegabytes: megabytes)
            for (index, file) in fixtures.files.enumerated() {
                await h.add(h.snapshot(String(format: "a%04d", index), daysAgo: Double(1 + index % 5), type: file.isVideo ? .video : .image))
            }
            let byId = Dictionary(uniqueKeysWithValues: fixtures.files.enumerated().map { (String(format: "a%04d", $0.offset), $0.element.url) })
            h.photos.exportOverride = { localId, _, destination, control in
                guard let file = byId[localId] else { throw PhotosSourceError.assetNotFound(localId: localId) }
                return try BenchmarkFixtures.streamExport(file, to: destination, control: control)
            }
            return fixtures.files.count
        }
    }

    @Test func folderImport() async throws {
        try await run("folder-import") { h, base in
            let fixtures = try BenchmarkFixtures(in: base.appendingPathComponent("fixtures/Bench"), totalMegabytes: megabytes)
            let reader = StubFileMetadataReader()
            for (index, file) in fixtures.files.enumerated() {
                reader.set(file.name, ImportFolder.photo(at: h.clock.now.addingTimeInterval(-Double(1 + index % 5) * 86_400)))
            }
            let source = LocalFolderSource(id: .folder(), root: PlainURLRoot(fixtures.directory), metadata: reader)
            _ = try await h.coordinator.startFolderImport(source: source, displayName: "Bench", bookmark: nil)
            return fixtures.files.count
        }
    }

    /// Lists a folder of many small files (`PHOTOVAULT_MEMORY_BENCH_FILES`, default 10 000) the way an import starts.
    @Test func folderListing() async throws {
        let base = try TestFiles.temporaryDirectory("pv-membench")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = try Self.manySmallFiles(in: base.appendingPathComponent("Bench"))
        let source = LocalFolderSource(id: .folder(), root: PlainURLRoot(folder.url), metadata: StubFileMetadataReader())
        let before = MemoryProbe.read()
        let sampler = FootprintSampler()
        let entries = try await source.listFiles()
        let peak = sampler.stop()
        let after = MemoryProbe.read()
        print("MEMBENCH folder-listing: \(entries.count) entries; before \(MemoryProbe.megabytes(before.current)) MB, peak \(MemoryProbe.megabytes(peak)) MB (+\(MemoryProbe.megabytes(peak - before.current))), after \(MemoryProbe.megabytes(after.current)) MB")
        #expect(entries.count == folder.count)
    }

    /// Imports many small files (`PHOTOVAULT_MEMORY_BENCH_FILES`, default 10 000): database rows and listing, not bytes.
    @Test func manyFilesImport() async throws {
        try await run("many-files-import", destinations: "drive") { h, base in
            let folder = try Self.manySmallFiles(in: base.appendingPathComponent("Bench"))
            let reader = StubFileMetadataReader()
            for index in 0..<folder.count {
                reader.set(Self.smallFileName(index), ImportFolder.photo(at: h.clock.now.addingTimeInterval(-Double(1 + index % 30) * 86_400)))
            }
            let source = LocalFolderSource(id: .folder(), root: PlainURLRoot(folder.url), metadata: reader)
            _ = try await h.coordinator.startFolderImport(source: source, displayName: "Bench", bookmark: nil)
            return folder.count
        }
    }

    private static func smallFileName(_ index: Int) -> String { String(format: "d%03d/IMG_%05d.JPG", index / 500, index) }

    private static func manySmallFiles(in directory: URL) throws -> (url: URL, count: Int) {
        let count = Int(ProcessInfo.processInfo.environment["PHOTOVAULT_MEMORY_BENCH_FILES"] ?? "") ?? 10_000
        for index in 0..<count {
            let url = directory.appendingPathComponent(smallFileName(index))
            if index % 500 == 0 { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
            FileManager.default.createFile(atPath: url.path, contents: Data("small-\(index)".utf8))
        }
        return (directory, count)
    }

    // MARK: Driver

    /// Runs cycles until every file of the scenario is at every destination. `prepare` adds the work and returns the file count.
    private func run(_ name: String, destinations: String? = nil, prepare: (Harness, URL) async throws -> Int) async throws {
        let base = try TestFiles.temporaryDirectory("pv-membench")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try Store.open(at: base.appendingPathComponent("db/photovault.sqlite"))
        let h = try await Harness(store: store)
        defer { try? FileManager.default.removeItem(at: h.root) }
        let server = BenchmarkDriveServer()
        let drive = GoogleDriveDestination(transport: BenchmarkDriveProtocol.transport(server), auth: BenchmarkDriveAuth(),
                                           rootId: "root", writeLimiter: nil, clock: h.clock)
        h.overrides = [drive]
        let nas = base.appendingPathComponent("nas", isDirectory: true)
        try FileManager.default.createDirectory(at: nas, withIntermediateDirectories: true)
        _ = try await h.useRealLocal(root: nas)
        // `MEMBENCH_DESTINATIONS=drive` or `=local` narrows the run to one destination.
        let only = ProcessInfo.processInfo.environment["MEMBENCH_DESTINATIONS"] ?? destinations
        var ids: [DestinationID] = []
        if only != "local" { try h.addDrive(); ids.append(.googleDrive) }
        if only != "drive" { try h.addNAS(); ids.append(h.nasId) }
        try await h.coordinator.beginBaseline(destinations: ids)

        let fileCount = try await prepare(h, base)
        let before = MemoryProbe.read()
        let sampler = FootprintSampler()
        var cycles = 0
        while cycles < 200 {
            cycles += 1
            await h.run()
            h.clock.advance(by: 60)
            if try h.jobs(.pending).isEmpty, try h.jobs(.uploading).isEmpty, try h.jobs(.done).count >= fileCount * ids.count { break }
        }
        let peak = sampler.stop()
        let after = MemoryProbe.read()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let settled = MemoryProbe.read()
        let heap = MemoryProbe.heap()
        print("""
            MEMBENCH \(name): \(fileCount) files, \(cycles) cycles, \
            drive files \(server.fileCount), done jobs \(try h.jobs(.done).count)
            MEMBENCH \(name): before \(MemoryProbe.megabytes(before.current)) MB, peak \(MemoryProbe.megabytes(peak)) MB \
            (+\(MemoryProbe.megabytes(peak - before.current))), after \(MemoryProbe.megabytes(after.current)) MB, \
            after 1 s \(MemoryProbe.megabytes(settled.current)) MB, lifetime peak \(MemoryProbe.megabytes(settled.lifetimePeak)) MB
            MEMBENCH \(name): heap in use \(MemoryProbe.megabytes(heap.inUse)) MB, held \(MemoryProbe.megabytes(heap.held)) MB
            """)
        if let tool = ProcessInfo.processInfo.environment["MEMBENCH_TOOL"] {
            // For example "vmmap --summary" or "heap": a diagnostic tool run on this process.
            let parts = tool.split(separator: " ").map(String.init)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/" + parts[0])
            process.arguments = Array(parts.dropFirst()) + [String(getpid())]
            try process.run()
            process.waitUntilExit()
        }
        #expect(try h.jobs(.done).count == fileCount * ids.count)
    }
}
