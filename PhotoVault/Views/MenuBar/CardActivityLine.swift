import PhotoVaultAppSupport
import SwiftUI

/// The line under a card's progress bar that says what is happening now, with a small spinner while it is.
struct CardActivityLine: View {
    var text: String
    var isBusy: Bool
    var isWaiting = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if isBusy { ProgressView().controlSize(.mini) }
            Text(text).font(.caption).monospacedDigit()
                .foregroundStyle(isWaiting ? Color.orange : Color.secondary)
                .lineLimit(2).truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
