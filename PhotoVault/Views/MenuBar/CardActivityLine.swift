import PhotoVaultAppSupport
import SwiftUI

/// The line under a card's progress bar that says what is happening now. It is always one line tall, even
/// with nothing to say, and its spinner fades instead of going away, so the card never changes height and
/// the text never shifts sideways.
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

/// A `FittedLine` on exactly one line, with the whole text in the tooltip. When it does not fit, the place
/// is cut first, then the lead loses its middle (it ends with the file name, so the extension stays); the
/// numbers stay whole.
struct FittedLineText: View {
    var line: FittedLine

    var body: some View {
        HStack(spacing: 0) {
            // An empty Text has no height; a space keeps the line's slot.
            Text(line.lead.isEmpty ? " " : line.lead).truncationMode(.middle).layoutPriority(1)
            if !line.place.isEmpty { Text(line.place).truncationMode(.tail) }
            if !line.detail.isEmpty { Text(line.detail).layoutPriority(2) }
        }
        .lineLimit(1)
        .monospacedDigit()
        .help(line.text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.text)
    }
}

#Preview("Card activity lines") {
    VStack(alignment: .leading, spacing: 4) {
        CardActivityLine(
            line: FittedLine(
                lead: "Uploading Holiday in Da Lat 2026 - fi…(final v3).MOV", place: " to Google Drive (someone@example.com)",
                detail: " · 1.2 / 2.6 GB (46%) · 1:02:05 · +12 more files"),
            isBusy: true)
        CardActivityLine(line: FittedLine(lead: "Uploading IMG_1234.HEIC", place: " to Google Drive", detail: " · 3.1 / 4.0 MB (77%)"), isBusy: true)
        CardActivityLine(line: FittedLine(lead: "Retrying in 0:42"), isBusy: false, isWaiting: true)
        CardActivityLine(line: nil, isBusy: false)
    }
    .padding(12)
    .frame(width: PopoverLayout.width)
}
