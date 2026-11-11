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
            SlotSpinner(isBusy: isBusy)
            FittedLineText(line: line ?? FittedLine(lead: ""))
                .font(.caption)
                .foregroundStyle(isWaiting ? Color.orange : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        // An empty slot is only there to keep the card's height; VoiceOver should not stop on it.
        .accessibilityHidden(!isBusy && (line?.text.isEmpty ?? true))
    }
}

/// A mini spinner that keeps its place when nothing is busy. A spinner hidden by opacity keeps its
/// AppKit indicator and goes on animating unseen; `hidden()` keeps only its size, so nothing animates.
struct SlotSpinner: View {
    var isBusy: Bool

    var body: some View {
        if isBusy {
            ProgressView().controlSize(.mini)
        } else {
            ProgressView().controlSize(.mini).hidden().accessibilityHidden(true)
        }
    }
}
