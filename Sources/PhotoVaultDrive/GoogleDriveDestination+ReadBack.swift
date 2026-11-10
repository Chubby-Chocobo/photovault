import Foundation
import PhotoVaultCore

extension GoogleDriveDestination: SmallFileReading {
    public func readSmallFile(remoteId: String, maxBytes: Int) async throws -> Data? {
        let media = DriveURL.make(DriveURL.api, "/files/" + FormEncoding.escape(remoteId), [("alt", "media"), ("supportsAllDrives", "true")])
        let buffer = ReadBackBuffer(limit: maxBytes)
        do {
            try await api.http.download(media) { chunk in try buffer.append(chunk) }
        } catch is ReadBackBuffer.TooLarge {
            return nil
        } catch DestinationError.notFound {
            return nil
        } catch DestinationError.itemRejected {
            return nil
        }
        return buffer.data
    }
}

private final class ReadBackBuffer: @unchecked Sendable {
    struct TooLarge: Error {}
    private let lock = NSLock()
    private let limit: Int
    private var bytes = Data()

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard bytes.count + chunk.count <= limit else { throw TooLarge() }
        bytes.append(chunk)
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }
}
