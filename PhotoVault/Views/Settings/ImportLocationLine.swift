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

    private var location: ImportLocation? {
        item.kind == .localFolder
            ? ImportLocationText.macLocation(stored: item.location, resolvedPath: folder?.path)
            : item.location
    }

    var body: some View {
        Group {
            if let location {
                HStack(spacing: 8) {
                    Text(ImportLocationText.headline(location)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    if let others = ImportLocationText.othersLabel(location) { Text(others).fixedSize() }
                    Spacer(minLength: 4)
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
