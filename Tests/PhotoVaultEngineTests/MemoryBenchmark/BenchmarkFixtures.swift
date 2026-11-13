import Foundation
import PhotoVaultCore

/// Generated files for the memory benchmark: distinct content (distinct hashes), written in 1 MiB pieces so
/// generating them does not itself raise the footprint.
struct BenchmarkFixtures {
    struct File { var name: String; var url: URL; var size: Int; var isVideo: Bool }

    let directory: URL
    let files: [File]

    /// `totalMegabytes` split into 3 MiB photos and 30 MiB videos, about 60/40 by bytes.
    init(in directory: URL, totalMegabytes: Int) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let videoCount = max(1, totalMegabytes * 4 / 10 / 30)
        let photoCount = max(1, (totalMegabytes - videoCount * 30) / 3)
        var block = [UInt8](repeating: 0, count: 1 << 20)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in block.indices {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            block[index] = UInt8(truncatingIfNeeded: seed >> 33)
        }
        var made: [File] = []
        for index in 0..<(photoCount + videoCount) {
            let isVideo = index >= photoCount
            let name = isVideo ? String(format: "MOV_%04d.MOV", index) : String(format: "IMG_%04d.JPG", index)
            let url = directory.appendingPathComponent(name)
            let megabytes = isVideo ? 30 : 3
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            for piece in 0..<megabytes {
                // The first bytes of each MiB name the file and the piece, so every file and piece differs.
                let tag = Array("\(name)#\(piece)#".utf8)
                block.replaceSubrange(0..<tag.count, with: tag)
                try handle.write(contentsOf: Data(block))
            }
            try handle.close()
            made.append(File(name: name, url: url, size: megabytes << 20, isVideo: isVideo))
        }
        files = made
    }

    var totalBytes: Int { files.reduce(0) { $0 + $1.size } }

    /// Copies `file` into `destination` in `chunk`-sized pieces through the app's streaming writer, the way
    /// PhotoKit hands an export over in pieces.
    static func streamExport(_ file: URL, to destination: URL, control: ExportControl, chunk: Int = 1 << 20) throws -> ExportedFile {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try StreamingFileWriter(url: destination, control: control)
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while true {
            let more = try autoreleasepool { () throws -> Bool in
                guard let data = try input.read(upToCount: chunk), !data.isEmpty else { return false }
                guard writer.append(data) else {
                    writer.abort()
                    throw PhotosSourceError.cancelled
                }
                return true
            }
            if !more { break }
        }
        return try writer.finish()
    }
}
