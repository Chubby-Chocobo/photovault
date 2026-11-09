import Foundation
import PhotoVaultCore
import Testing
@testable import PhotoVaultAppSupport

struct LogRedactorTests {
    @Test func cleanMessagesPass() {
        #expect(LogRedactor.inspect("job 42 uploaded asset a1b2c3 in 3 attempts") == .clean)
        #expect(LogRedactor.sanitized("cycle ended with error: DestinationError") == "cycle ended with error: DestinationError")
    }

    @Test(arguments: [
        ("token ya29.a0AfH6SMBxxxxxxxxxxxxxxxx", "access token"),
        ("refresh 1//0gAbCdEfGhIjKlMnOpQrStUvWxYz", "refresh token"),
        ("Authorization: Bearer abcdefghijkl1234", "bearer token"),
        ("id eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjMifQ.sig", "jwt"),
        ("PUT https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=AAA", "session url"),
        ("opened /Users/annh/Pictures", "path"),
        ("root /Volumes/photo/PhotoVault", "path"),
        ("failed IMG_4821.HEIC", "file name"),
        ("sidecar DSC04410.arw missing", "file name"),
        ("geocode 11.940419, 108.458313", "coordinates"),
        ("account annh.photo@gmail.com", "e-mail"),
        ("secret GOCSPX-abcdEFGH1234", "client secret"),
    ])
    func sensitiveContentIsWithheld(sample: String, reason: String) {
        #expect(LogRedactor.inspect(sample) == .withheld(reason: reason))
        let safe = LogRedactor.sanitized(sample)
        #expect(safe == "[message withheld: contains \(reason)]")
        #expect(!safe.contains("annh"))
    }
}

struct RotatingFileLogTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pv-log-\(UUID().uuidString)", isDirectory: true)
    }

    private func files(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    @Test func writesFormattedLine() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = RotatingFileLog(directory: directory)
        log.log(.notice, category: "cycle", "started trigger=launch")
        log.close()
        let text = try String(contentsOf: log.currentFile, encoding: .utf8)
        #expect(text.contains("[NOTICE] cycle: started trigger=launch"))
        #expect(text.hasSuffix("\n"))
        let attributes = try FileManager.default.attributesOfItem(atPath: log.currentFile.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func redactsBeforeWriting() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = RotatingFileLog(directory: directory)
        log.log(.error, category: "export", "failed IMG_0001.HEIC at 10.123456, 106.123456")
        log.close()
        let text = try String(contentsOf: log.currentFile, encoding: .utf8)
        #expect(!text.contains("IMG_0001"))
        #expect(!text.contains("106.123456"))
        #expect(text.contains("message withheld"))
    }

    @Test func newlinesCannotForgeLogLines() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = RotatingFileLog(directory: directory)
        log.log(.info, category: "x", "first\n2026-01-01T00:00:00Z [ERROR] forged: line")
        log.close()
        let text = try String(contentsOf: log.currentFile, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 1)
    }

    @Test func rotatesAndKeepsAtMostFiveFiles() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = RotatingFileLog(directory: directory, maxBytes: 2048, fileCount: 5)
        let line = String(repeating: "a", count: 200)
        for index in 0..<200 { log.log(.info, category: "load", "\(index) \(line)") }
        log.close()
        let names = files(in: directory)
        #expect(names == ["photovault.1.log", "photovault.2.log", "photovault.3.log", "photovault.4.log", "photovault.log"])
        for name in names {
            let size = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.size] as? Int ?? 0
            #expect(size <= 2048)
        }
        let newest = try String(contentsOf: log.currentFile, encoding: .utf8)
        #expect(newest.contains("199 "))
        let oldest = try String(contentsOf: directory.appendingPathComponent("photovault.4.log"), encoding: .utf8)
        #expect(!oldest.contains("[INFO] load: 0 "))
    }

    @Test func appendsToExistingFileAfterRestart() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = RotatingFileLog(directory: directory)
        first.log(.info, category: "a", "one")
        first.close()
        let second = RotatingFileLog(directory: directory)
        second.log(.info, category: "a", "two")
        second.close()
        let text = try String(contentsOf: second.currentFile, encoding: .utf8)
        #expect(text.contains("one") && text.contains("two"))
    }

    @Test func longLinesAreClipped() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = RotatingFileLog(directory: directory)
        log.log(.info, category: "x", String(repeating: "b", count: 10_000))
        log.close()
        let text = try String(contentsOf: log.currentFile, encoding: .utf8)
        #expect(text.count < 2200)
    }

    @Test func concurrentWritersDoNotCorruptLines() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = RotatingFileLog(directory: directory)
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask { for index in 0..<50 { log.log(.info, category: "w\(worker)", "n=\(index)") } }
            }
        }
        log.close()
        let lines = try String(contentsOf: log.currentFile, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 400)
        #expect(lines.allSatisfy { $0.contains("[INFO]") })
    }
}
