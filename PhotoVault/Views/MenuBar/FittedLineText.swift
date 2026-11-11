import PhotoVaultAppSupport
import SwiftUI

/// A `FittedLine` on exactly one line, with the full text in the tooltip. It shows the richest form that fits:
/// everything, then without the place, then without the count of other files, and last the file name cut in
/// the middle (so its extension stays) between the action and the numbers, which stay whole.
struct FittedLineText: View {
    var line: FittedLine

    var body: some View {
        ViewThatFits(in: .horizontal) {
            whole(place: true, others: true)
            if !line.place.isEmpty { whole(place: false, others: true) }
            if !line.others.isEmpty { whole(place: false, others: false) }
            HStack(spacing: 0) {
                if !line.prefix.isEmpty { Text(line.prefix).layoutPriority(3) }
                // An empty Text has no height; a space keeps the line's slot.
                Text(line.lead.isEmpty ? " " : line.lead).truncationMode(.middle).layoutPriority(1)
                if !line.detail.isEmpty { Text(line.detail).layoutPriority(2) }
            }
        }
        .lineLimit(1)
        .monospacedDigit()
        .help(line.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.help)
        .accessibilityHidden(line.text.isEmpty)
    }

    /// The line without cuts, dropping the place or the count of the others when asked.
    private func whole(place: Bool, others: Bool) -> some View {
        let text = line.prefix + line.lead + (place ? line.place : "") + line.detail + (others ? line.others : "")
        return Text(text.isEmpty ? " " : text).fixedSize(horizontal: true, vertical: false)
    }
}

#Preview("Fitted lines") {
    let long = FittedLine(
        prefix: "Uploading ", lead: "Holiday in Da Lat 2026…v3).MOV", place: " to Google Drive (someone@example.com)",
        detail: " · 1.2 / 2.6 GB (46%) · 1:02:05", others: " · +12 more files")
    VStack(alignment: .leading, spacing: 4) {
        CardActivityLine(line: long, isBusy: true)
        CardActivityLine(line: FittedLine(prefix: "Uploading ", lead: "IMG_1234.HEIC", place: " to Google Drive", detail: " · 3.1 / 4.0 MB (77%)"), isBusy: true)
        CardActivityLine(line: FittedLine(lead: "Retrying in 0:42"), isBusy: false, isWaiting: true)
        CardActivityLine(line: nil, isBusy: false)
        FittedLineText(line: long).font(.caption).frame(width: 200, alignment: .leading)
    }
    .padding(12)
    .frame(width: PopoverLayout.width)
}
