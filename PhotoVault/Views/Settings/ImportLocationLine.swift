import AppKit
import PhotoVaultAppSupport
import PhotoVaultCore
import PhotoVaultEngine
import SwiftUI

/// "Where from" caption of an import row: the path (middle-truncated, selectable, full text as tooltip) and a
/// small link to Finder or the web. Older Mac imports find their path from the bookmark when the row appears.
struct ImportLocationLine: View {
    @Environment(AppModel.self) private var model
    var item: ImportSnapshot
    @State private var folder: URL?
    @State private var showFull = false

    private var location: ImportLocation? {
        item.kind == .localFolder
            ? ImportLocationText.macLocation(stored: item.location, resolvedPath: folder?.path)
            : item.location
    }

    /// The path, shortened by whole components until it fits the row; a click shows all of it.
    private func headline(_ location: ImportLocation) -> some View {
        let full = ImportLocationText.headline(location)
        return ViewThatFits(in: .horizontal) {
            ForEach(ImportLocationShortener.variants(full, budgets: [200, 60, 45, 32, 22]), id: \.self) { text in
                Text(text).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
            Text(ImportLocationShortener.shorten(full, budget: 22)).lineLimit(1).truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onTapGesture { showFull = true }
        .popover(isPresented: $showFull, arrowEdge: .bottom) {
            Text(ImportLocationText.tooltip(location) ?? full)
                .textSelection(.enabled).font(.callout).padding(12)
                .frame(width: 360, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copy(_ location: ImportLocation) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ImportLocationText.tooltip(location) ?? "", forType: .string)
    }

    var body: some View {
        Group {
            if let location {
                HStack(spacing: 8) {
                    headline(location)
                    if let others = ImportLocationText.othersLabel(location) { Text(others).fixedSize() }
                    Spacer(minLength: 4)
                    Button { copy(location) } label: { Image(systemName: "doc.on.doc") }
                        .help(ImportLocationText.copyTitle).accessibilityLabel(ImportLocationText.copyTitle)
                    if let folder {
                        Button(ImportLocationText.revealTitle) { model.revealInFinder(folder) }
                    } else if let url = location.webURL {
                        Button(ImportLocationText.openOnWebTitle) { model.openOnWeb(url) }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .help(ImportLocationText.tooltip(location) ?? "")
                .buttonStyle(.link).controlSize(.small)
            }
        }
        .task(id: item.id) {
            if item.kind == .localFolder { folder = await model.resolveImportFolder(item.id) }
        }
    }
}
