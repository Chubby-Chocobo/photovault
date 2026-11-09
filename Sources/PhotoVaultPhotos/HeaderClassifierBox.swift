import Foundation
import os

/// Lock-protected `HeaderClassifier` shared with PhotoKit's data handler.
final class HeaderClassifierBox: @unchecked Sendable {
    private struct State {
        var classifier: HeaderClassifier
        var stoppedEarly = false
    }

    private let state: OSAllocatedUnfairLock<State>

    init(typeHint: String?, maxBuffered: Int = HeaderClassifier.defaultMaxBuffered) {
        state = OSAllocatedUnfairLock(uncheckedState: State(classifier: HeaderClassifier(maxBuffered: maxBuffered, typeHint: typeHint)))
    }

    /// Feeds a chunk; returns `true` once the answer is conclusive and the read should stop.
    func append(_ data: Data) -> Bool {
        state.withLock { s in
            let outcome = s.classifier.append(data)
            if outcome.isConclusive { s.stoppedEarly = true }
            return outcome.isConclusive
        }
    }

    func finish() -> HeaderClassifier.Outcome { state.withLock { $0.classifier.finish() } }
    var outcome: HeaderClassifier.Outcome { state.withLock { $0.classifier.outcome } }
    var stoppedEarly: Bool { state.withLock { $0.stoppedEarly } }
    var overflowed: Bool { state.withLock { $0.classifier.overflowed } }
}
