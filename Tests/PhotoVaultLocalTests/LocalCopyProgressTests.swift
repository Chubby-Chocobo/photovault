import Foundation
import PhotoVaultCore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultLocal

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    func add(_ value: Int64) { lock.withLock { values.append(value) } }
    var all: [Int64] { lock.withLock { values } }
}

@Suite struct LocalCopyProgressTests {
    @Test func copyReportsGrowingByteCountsEndingAtTheFileSize() async throws {
        let fx = try LocalFixture()
        let folder = try await fx.folder("a")
        // Three chunks of the copy buffer.
        let text = String(repeating: "x", count: FileHashing.chunkSize * 2 + 100)
        var request = try fx.request("big.MOV", text, in: folder)
        let reports = Reports()
        request.progress = TransferSink { reports.add($0) }
        _ = try await fx.upload(request)
        let values = reports.all
        #expect(values.count >= 3, "\(values)")
        #expect(values == values.sorted())
        #expect(values.last == Int64(text.utf8.count))
    }

    @Test func replacingAnEditedFileReportsToo() async throws {
        let fx = try LocalFixture()
        let folder = try await fx.folder("a")
        let first = try await fx.upload(try fx.request("x.JPG", "v1", in: folder))
        var request = try fx.request("x.JPG", "version two", in: folder, prior: first.verifiedHash)
        let reports = Reports()
        request.progress = TransferSink { reports.add($0) }
        _ = try await fx.destination.replaceContent(remoteId: first.remoteId, request)
        #expect(reports.all.last == Int64("version two".utf8.count))
    }
}
