import Foundation
import PhotoVaultAppSupport
import PhotoVaultCore

extension AppModel {
    /// The status line text for the files moving now; nil when none has run long enough to show.
    var transferLine: String? {
        _ = transferNow  // re-evaluated by the one-second clock while files move
        return TransferLineText.make(transfers, now: Date())
    }

    func show(transfers list: [TransferProgress]) {
        transfers = list
        transferNow = Date()
        // The clock stops itself at its next tick once the list is empty, so a stream of short files does not
        // start and cancel a task for each.
        guard !list.isEmpty, transferClockTask == nil else { return }
        // A transfer appears once it has run a second even when no bytes arrive meanwhile (a long upload chunk).
        transferClockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1), tolerance: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                self.transferNow = Date()
                if self.transfers.isEmpty {
                    self.transferClockTask = nil
                    return
                }
            }
        }
    }
}
