import Foundation
import PhotoVaultCore
import PhotoVaultStore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lists: [[TransferProgress]] = []
    func add(_ list: [TransferProgress]) { lock.withLock { lists.append(list) } }
    var all: [[TransferProgress]] { lock.withLock { lists } }
    /// Every transfer ever shown, in order.
    var seen: [TransferProgress] { lock.withLock { lists.flatMap { $0 } } }
    var last: [TransferProgress] { lock.withLock { lists.last ?? [] } }
}

private extension Harness {
    /// Publishes every report so a test sees each chunk.
    func recordTransfers() -> Recorder {
        let recorder = Recorder()
        env.transfers = TransferTracker(clock: clock, minInterval: 0, onPublish: { recorder.add($0) })
        coordinator = SyncCoordinator(env: env)
        return recorder
    }
}

@Suite struct TransferProgressPipelineTests {
    @Test func photosExportShowsTheOriginalNameAndBytesThenClears() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("one"), recordChange: false)
        try await h.baseline(.googleDrive)
        let recorder = h.recordTransfers()
        h.photos.beforeExport = { _, _, control in
            _ = control.record(bytes: 10)
            _ = control.record(bytes: 15)
        }
        await h.run()
        let exports = recorder.seen.filter { $0.kind == .exportFromPhotos }
        #expect(exports.contains { $0.fileName == "IMG_one.HEIC" && $0.bytesDone == 25 }, "\(recorder.all.count) lists")
        #expect(exports.allSatisfy { $0.destinationName == nil })
        #expect(recorder.last.isEmpty && h.env.transfers.current.isEmpty)
    }

    @Test func aFailedExportClearsTheTransfer() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("bad"), recordChange: false)
        try await h.baseline(.googleDrive)
        let recorder = h.recordTransfers()
        h.photos.beforeExport = { _, _, control in
            _ = control.record(bytes: 10)
            throw PhotosSourceError.networkError
        }
        await h.run()
        #expect(recorder.seen.contains { $0.kind == .exportFromPhotos && $0.bytesDone == 10 })
        #expect(h.env.transfers.current.isEmpty && recorder.last.isEmpty)
    }

    @Test func driveUploadShowsDestinationNameChunksAndTotal() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("one"), recordChange: false)
        try await h.baseline(.googleDrive)
        let recorder = h.recordTransfers()
        await h.drive.setUploadHook { request in
            request.progress?.report(request.content.size / 2)
            request.progress?.report(request.content.size)
        }
        await h.run()
        let uploads = recorder.seen.filter { $0.kind == .upload }
        let total = try #require(uploads.first?.bytesTotal)
        #expect(uploads.allSatisfy { $0.fileName == "IMG_one.HEIC" && $0.destinationName == "Drive" && $0.bytesTotal == total })
        #expect(uploads.contains { $0.bytesDone == total / 2 } && uploads.contains { $0.bytesDone == total })
        #expect(recorder.last.isEmpty && h.env.transfers.current.isEmpty)
    }

    @Test func localFolderWriteIsACopy() async throws {
        let h = try await Harness()
        try h.addNAS(scope: .full)
        await h.add(h.snapshot("one"), recordChange: false)
        try await h.baseline(h.nasId)
        let recorder = h.recordTransfers()
        await h.nas.setUploadHook { $0.progress?.report($0.content.size) }
        await h.run()
        #expect(recorder.seen.contains { $0.kind == .copy && $0.fileName == "IMG_one.HEIC" && $0.destinationName == "NAS" })
        #expect(!recorder.seen.contains { $0.kind == .upload })
        #expect(h.env.transfers.current.isEmpty)
    }

    @Test func aFailedUploadClearsTheTransfer() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        await h.add(h.snapshot("one"), recordChange: false)
        try await h.baseline(.googleDrive)
        let recorder = h.recordTransfers()
        await h.drive.failNext(.upload, with: .itemRejected(reason: "test"))
        await h.run()
        #expect(recorder.seen.contains { $0.kind == .upload })
        #expect(h.env.transfers.current.isEmpty && recorder.last.isEmpty)
    }

    @Test func folderImportReadShowsTheItemName() async throws {
        let h = try await Harness()
        try h.addDrive(scope: .full)
        try await h.baseline(.googleDrive)
        let recorder = h.recordTransfers()
        let folder = try ImportFolder()
        try folder.add("trip/clip.jpg", metadata: ImportFolder.photo(at: h.clock.now.addingTimeInterval(-3 * 86_400)))
        _ = try await h.startImport(folder)
        let reads = recorder.seen.filter { $0.kind == .download(.localFolder) }
        #expect(reads.contains { $0.fileName == "clip.jpg" && $0.bytesDone > 0 && $0.bytesTotal == $0.bytesDone }, "\(reads.count)")
        #expect(h.env.transfers.current.isEmpty && recorder.last.isEmpty)
    }
}
