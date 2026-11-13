import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultAppSupport

@Suite struct LogReaderTests {
    private func directory(_ files: [String: [String]]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("logreader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, lines) in files {
            try (lines.joined(separator: "\n") + "\n").write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return url
    }

    @Test func parsesTheFormatTheFileLogWrites() {
        let line = RotatingFileLog.format(level: .notice, category: "cycle", message: "photos unavailable: ending", date: Date(timeIntervalSince1970: 1_794_200_000.512))
        #expect(line.hasPrefix("2026-11-09T") && line.contains(".512Z [NOTICE]"), "milliseconds are written")
        let entry = LogReader.parse(String(line.dropLast()), id: "0")
        #expect(abs((entry.date?.timeIntervalSince1970 ?? 0) - 1_794_200_000.512) < 0.001)
        #expect(entry.level == .notice)
        #expect(entry.category == "cycle")
        #expect(entry.message == "photos unavailable: ending")
    }

    @Test func keepsLinesThatDoNotFollowTheFormat() {
        let entry = LogReader.parse("something else", id: "3")
        #expect(entry.date == nil && entry.level == nil && entry.message == "something else")
    }

    @Test func readsNewestFirstAcrossRotatedFilesUpToTheLimit() throws {
        let dir = try directory([
            "photovault.log": ["2026-11-09T10:00:03Z [INFO] a: three", "2026-11-09T10:00:04Z [ERROR] b: four"],
            "photovault.1.log": ["2026-11-09T10:00:01Z [INFO] a: one", "2026-11-09T10:00:02Z [NOTICE] a: two"],
        ])
        let reader = LogReader(directory: dir)
        #expect(reader.read().map(\.message) == ["four", "three", "two", "one"])
        #expect(reader.read(limit: 3).map(\.message) == ["four", "three", "two"])
        #expect(reader.stamp() != nil)
        #expect(reader.read().map(\.id) == reader.read().map(\.id), "ids survive a reload")
        #expect(LogReader(directory: dir.appendingPathComponent("missing")).read().isEmpty)
    }

    @Test func filtersByLevelAndSearchAndCopiesOldestFirst() throws {
        let dir = try directory(["photovault.log": [
            "2026-11-09T10:00:00Z [DEBUG] drive.http: GET files -> 200",
            "2026-11-09T10:00:01Z [INFO] upload: done dest=googleDrive",
            "2026-11-09T10:00:02Z [NOTICE] destination: status active -> unavailable(offline)",
            "2026-11-09T10:00:03Z [ERROR] cycle: cycle ended with error: DriveError",
        ]])
        let entries = LogReader(directory: dir).read()
        #expect(LogReader.filter(entries, level: .everything, query: "").count == 4)
        #expect(LogReader.filter(entries, level: .standard, query: "").count == 3, "detail lines are hidden")
        #expect(LogReader.filter(entries, level: .problems, query: "").map(\.category) == ["cycle", "destination"])
        #expect(LogReader.filter(entries, level: .standard, query: "OFFLINE").map(\.category) == ["destination"])
        #expect(LogReader.text(LogReader.filter(entries, level: .problems, query: "")) == """
            2026-11-09T10:00:02Z [NOTICE] destination: status active -> unavailable(offline)
            2026-11-09T10:00:03Z [ERROR] cycle: cycle ended with error: DriveError
            """)
    }

    @Test func readingTheEndOfAFileGivesTheSameLinesAsReadingItWhole() throws {
        // Lines of varied length, some with multi-byte characters, so pieces start at awkward offsets.
        let lines = (0..<400).map { "2026-11-09T10:00:00Z [INFO] cycle: dòng \($0) " + String(repeating: "ảnh·", count: $0 % 37) }
        let dir = try directory(["photovault.log": lines])
        let url = dir.appendingPathComponent("photovault.log")
        let whole = String(decoding: try Data(contentsOf: url), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        for needed in [1, 7, 100, 399, 400, 1000] {
            for firstPiece: UInt64 in [1, 13, 64, 1 << 20] {
                let tail = try #require(LogReader.lastLines(of: url, needed: needed, firstPiece: firstPiece))
                #expect(tail.count >= min(needed, whole.count), "needed \(needed), piece \(firstPiece)")
                #expect(Array(whole.suffix(tail.count)) == tail, "needed \(needed), piece \(firstPiece)")
            }
        }
        #expect(LogReader.lastLines(of: dir.appendingPathComponent("missing.log"), needed: 1) == nil)
    }

    @Test func repeatedLinesGetDistinctIdsAndOnlyNewlinesSplit() throws {
        let dir = try directory(["photovault.log": ["same", "same", "a\u{2028}b"]])
        let entries = LogReader(directory: dir).read()
        #expect(entries.count == 3)
        #expect(Set(entries.map(\.id)).count == 3)
        #expect(entries[0].message == "a\u{2028}b")
    }
}
