import Foundation
import os
import PhotoVaultCore
import Testing
@testable import PhotoVaultPhotos

@Suite struct StalledRequestGuardTests {
    final class Calls: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: (cancels: 0, chunks: 0))
        func cancelled() { lock.withLock { $0.cancels += 1 } }
        func chunk() { lock.withLock { $0.chunks += 1 } }
        var cancels: Int { lock.withLock { $0.cancels } }
        var chunks: Int { lock.withLock { $0.chunks } }
    }

    private let fast = StalledRequestGuard(stallTimeout: 0.2, checkInterval: 0.05)

    @Test func aRequestThatNeverDeliversIsCancelledAndReportedAsANetworkError() async throws {
        let calls = Calls()
        await #expect(throws: PhotosSourceError.networkError) {
            try await fast.run(start: { _, _ in }, cancel: { calls.cancelled() }, onChunk: { _ in true })
        }
        #expect(calls.cancels == 1)
    }

    @Test func steadyChunksKeepALongRequestAlive() async throws {
        let calls = Calls()
        try await fast.run(start: { chunk, completion in
            Task.detached {
                for _ in 0..<8 {
                    try? await Task.sleep(for: .milliseconds(60))
                    _ = chunk(Data([1]))
                }
                completion(nil)
            }
        }, cancel: { calls.cancelled() }, onChunk: { _ in calls.chunk(); return true })
        #expect(calls.chunks == 8 && calls.cancels == 0)
    }

    @Test func aLateCompletionAfterAStallIsIgnored() async throws {
        let late = OSAllocatedUnfairLock<(@Sendable (Error?) -> Void)?>(initialState: nil)
        await #expect(throws: PhotosSourceError.networkError) {
            try await fast.run(start: { _, completion in late.withLock { $0 = completion } }, cancel: {}, onChunk: { _ in true })
        }
        late.withLock { $0 }?(nil)
    }

    @Test func taskCancellationReturnsCancelledEvenIfTheRequestNeverCompletes() async throws {
        let calls = Calls()
        let slow = StalledRequestGuard(stallTimeout: 60, checkInterval: 0.05)
        let task = Task { try await slow.run(start: { _, _ in }, cancel: { calls.cancelled() }, onChunk: { _ in true }) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: PhotosSourceError.cancelled) { try await task.value }
        #expect(calls.cancels == 1)
    }

    @Test func startFailuresAreThrown() async throws {
        await #expect(throws: PhotosSourceError.assetNotFound(localId: "x")) {
            try await fast.run(start: { _, _ in throw PhotosSourceError.assetNotFound(localId: "x") }, cancel: {}, onChunk: { _ in true })
        }
    }
}
