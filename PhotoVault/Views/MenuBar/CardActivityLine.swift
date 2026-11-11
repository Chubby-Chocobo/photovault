import PhotoVaultAppSupport
import SwiftUI

/// The line under a card's progress bar that says what is happening now. It is always one line tall, even
/// with nothing to say, and its spinner is hidden in place instead of going away, so the card never changes
/// height and the text never shifts sideways.
struct CardActivityLine: View {
    /// nil keeps the slot empty.
    var line: FittedLine?
    var isBusy: Bool
    var isWaiting = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ProgressView().controlSize(.mini)
                .opacity(isBusy ? 1 : 0).accessibilityHidden(!isBusy)
            FittedLineText(line: line ?? FittedLine(lead: ""))
                .font(.caption)
                .foregroundStyle(isWaiting ? Color.orange : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
