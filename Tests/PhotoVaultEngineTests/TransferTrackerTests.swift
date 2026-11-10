import Foundation
import PhotoVaultCore
import PhotoVaultTestSupport
import Testing
@testable import PhotoVaultEngine

private final class Published: @unchecked Sendable {
    private let lock = NSLock()
    private var lists: [[TransferProgress]] = []
    func add(_ list: [TransferProgress]) { lock.withLock { lists.append(list) } }
    var all: [[TransferProgress]] { lock.withLock { lists } }
}

@Suite struct TransferTrackerTests {
    private func make(interval: TimeInterval = 0.5) -> (TransferTracker, TestClock, Published) {
        let clock = TestClock()
        let published = Published()
        let tracker = TransferTracker(clock: clock, minInterval: interval, onPublish: { published.add($0) })
        return (tracker, clock, published)
    }

    @Test func beginExposesKindNamesTotalAndStartTime() {
        let (tracker, clock, published) = make()
        let handle = tracker.begin(kind: .upload, fileName: "IMG_1.MOV", destinationName: "Google Drive", bytesTotal: 100)
        let item = tracker.current.first
        #expect(tracker.current.count == 1)
        #expect(item?.kind == .upload)
        #expect(item?.fileName == "IMG_1.MOV")
        #expect(item?.destinationName == "Google Drive")
        #expect(item?.bytesTotal == 100)
        #expect(item?.bytesDone == 0)
        #expect(item?.startedAt == clock.now)
        #expect(published.all.count == 1)
        handle.end()
    }

    @Test func reportsAreSeenCumulativelyAndEndClears() {
        let (tracker, clock, published) = make()
        let handle = tracker.begin(kind: .copy, fileName: "a.jpg", destinationName: "NAS", bytesTotal: 100)
        clock.advance(by: 1)
        handle.sink.report(40)
        #expect(tracker.current.first?.bytesDone == 40)
        clock.advance(by: 1)
        handle.sink.report(100)
        #expect(published.all.last?.first?.bytesDone == 100)
        handle.end()
        #expect(tracker.current.isEmpty)
        #expect(published.all.last?.isEmpty == true)
    }

    @Test func publishingIsThrottledButTheCurrentValueIsAlwaysFresh() {
        let (tracker, clock, published) = make(interval: 0.5)
        let handle = tracker.begin(kind: .exportFromPhotos, fileName: "a.mov", bytesTotal: 1000)
        for step in 1...20 {
            clock.advance(by: 0.01)
            handle.sink.report(Int64(step))
        }
        // The begin publication only; 0.2 s passed.
        #expect(published.all.count == 1)
        #expect(tracker.current.first?.bytesDone == 20)
        clock.advance(by: 0.5)
        handle.sink.report(21)
        #expect(published.all.count == 2)
        #expect(published.all.last?.first?.bytesDone == 21)
        handle.end()
        // Ending is never throttled.
        #expect(published.all.count == 3)
        #expect(published.all.last?.isEmpty == true)
    }

    @Test func manyShortOverlappingTransfersPublishOnlyWhenTheListFillsAndEmpties() {
        let (tracker, clock, published) = make(interval: 0.5)
        var handles: [TransferTracker.Handle] = []
        for index in 0..<100 {
            clock.advance(by: 0.001)
            handles.append(tracker.begin(kind: .upload, fileName: "f\(index)", destinationName: "Drive", bytesTotal: 10))
        }
        #expect(tracker.current.count == 100)
        for handle in handles.dropLast() {
            clock.advance(by: 0.001)
            handle.end()
        }
        // Filling the empty list published once; the others were inside the throttle window.
        #expect(published.all.count == 1)
        #expect(tracker.current.count == 1)
        handles.last?.end()
        #expect(published.all.count == 2 && published.all.last?.isEmpty == true)
    }

    @Test func aTransferThatBeginsWhileOthersRunIsPublishedOnceTheWindowHasPassed() {
        let (tracker, clock, published) = make(interval: 0.5)
        let first = tracker.begin(kind: .upload, fileName: "first", bytesTotal: 10)
        clock.advance(by: 0.6)
        let second = tracker.begin(kind: .copy, fileName: "second", bytesTotal: 10)
        #expect(published.all.count == 2 && published.all.last?.count == 2)
        first.end()
        second.end()
    }

    @Test func endIsIdempotentAndLateReportsAreIgnored() {
        let (tracker, clock, published) = make()
        let handle = tracker.begin(kind: .upload, fileName: "a", bytesTotal: nil)
        handle.end()
        let count = published.all.count
        handle.end()
        clock.advance(by: 5)
        handle.sink.report(10)
        #expect(tracker.current.isEmpty)
        #expect(published.all.count == count)
    }

    @Test func severalTransfersRunAtOnceInStartOrder() {
        let (tracker, clock, _) = make()
        let first = tracker.begin(kind: .upload, fileName: "first", destinationName: "Drive", bytesTotal: 10)
        clock.advance(by: 2)
        let second = tracker.begin(kind: .copy, fileName: "second", destinationName: "NAS", bytesTotal: 10)
        #expect(tracker.current.map(\.fileName) == ["first", "second"])
        first.end()
        #expect(tracker.current.map(\.fileName) == ["second"])
        second.end()
        #expect(tracker.current.isEmpty)
    }

    @Test func exportControlForwardsReceivedBytes() {
        let (tracker, clock, _) = make(interval: 0)
        let handle = tracker.begin(kind: .exportFromPhotos, fileName: "a.mov", bytesTotal: nil)
        let control = ExportControl()
        control.setProgress(handle.sink)
        clock.advance(by: 1)
        _ = control.record(bytes: 300)
        _ = control.record(bytes: 200)
        #expect(tracker.current.first?.bytesDone == 500)
        #expect(tracker.current.first?.bytesTotal == nil)
        handle.end()
    }

    @Test func descriptionRedactsNames() {
        var item = TransferProgress(kind: .upload, fileName: "Holiday-Anna.MOV", destinationName: "Anna NAS", bytesDone: 5, startedAt: Date())
        item.accountEmail = "anna@example.com"
        for text in ["\(item)", String(describing: item), String(reflecting: item), "\(TransferKind.download(.dropbox))"] {
            #expect(!text.contains("Holiday"))
            #expect(!text.contains("Anna"))
            #expect(!text.contains("example.com"))
        }
        #expect("\(item)".contains("redacted"))
    }

    @Test func updatesStreamReplaysTheLatestList() async {
        let (tracker, _, _) = make()
        let handle = tracker.begin(kind: .upload, fileName: "a", bytesTotal: 1)
        var iterator = tracker.updates().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.count == 1)
        handle.end()
        let second = await iterator.next()
        #expect(second?.isEmpty == true)
    }
}
